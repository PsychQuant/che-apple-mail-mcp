import XCTest
import Darwin
@testable import CheAppleMailMCP

/// Real macOS filesystem tests. Synthetic stages are not native Mail evidence.
final class AttachmentQuarantineTests: XCTestCase {
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idd573-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testTier1PublishesFreshQuarantineAndReplacesOldApproval() throws {
        let root = try fixtureRoot(), target = root.appendingPathComponent("fixture.command")
        let destination = try AttachmentDestination(savePath: target.path, allowedRoots: [root.path])
        let started = Date()
        _ = try destination.publish(Data([0, 1, 255]))
        XCTAssertEqual(try Data(contentsOf: target), Data([0, 1, 255]))
        try assertFreshAttachmentQuarantine(target, since: started)
        try setFixtureQuarantine(target, value: "00c1;12345678;PriorApproval;")
        _ = try destination.publish(Data([3]))
        XCTAssertEqual(try Data(contentsOf: target), Data([3]))
        try assertFreshAttachmentQuarantine(target, since: started)
        try printAttachmentXattrs(target, label: "Tier 1 published")
    }

    func testTier2PublishesQuarantineWhenStageHasNone() throws {
        try checkSyntheticStage(quarantine: nil)
    }

    func testTier2DoesNotInheritPreviouslyApprovedStageMetadata() throws {
        try checkSyntheticStage(quarantine: "00c1;12345678;SyntheticSource;")
    }

    private func checkSyntheticStage(quarantine: String?) throws {
        let root = try fixtureRoot(), target = root.appendingPathComponent("fixture.zip")
        let destination = try AttachmentDestination(savePath: target.path, allowedRoots: [root.path])
        let started = Date()
        var stageParent: URL?
        _ = try destination.saveUsingScript({ path in
            let source = URL(fileURLWithPath: path)
            stageParent = source.deletingLastPathComponent()
            try Data([2, 0, 255, 4]).write(to: source)
            if let quarantine {
                try setFixtureQuarantine(source, value: quarantine)
            } else {
                if removexattr(path, "com.apple.quarantine", 0) != 0 && errno != ENOATTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                XCTAssertNil(try attachmentQuarantineValue(source))
            }
            try printAttachmentXattrs(source, label: "Tier 2 synthetic stage")
            return "Attachment saved"
        }, allowEmpty: false)
        XCTAssertEqual(try Data(contentsOf: target), Data([2, 0, 255, 4]))
        try assertFreshAttachmentQuarantine(target, since: started)
        try printAttachmentXattrs(target, label: "Tier 2 published")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stageParent).path))
    }

    func testAcceptedEmptyAttachmentsAreQuarantinedInBothTiers() throws {
        let root = try fixtureRoot()
        for scripted in [false, true] {
            let target = root.appendingPathComponent(scripted ? "script-empty" : "data-empty")
            let destination = try AttachmentDestination(savePath: target.path, allowedRoots: [root.path])
            let started = Date()
            if scripted {
                _ = try destination.saveUsingScript({ path in
                    try Data().write(to: URL(fileURLWithPath: path))
                    return "Attachment saved"
                }, allowEmpty: true)
            } else {
                _ = try destination.publish(Data(), allowEmpty: true)
            }
            XCTAssertEqual(try Data(contentsOf: target), Data())
            try assertFreshAttachmentQuarantine(target, since: started)
        }
    }

    func testPinnedParentAndLateLeafSymlinkCannotRedirectMetadataInEitherTier() throws {
        for scripted in [false, true] {
            let root = try fixtureRoot(), outside = try fixtureRoot()
            let parent = root.appendingPathComponent("parent"), moved = root.appendingPathComponent("moved")
            let destination = try AttachmentDestination(savePath: parent.path + "/file", allowedRoots: [root.path])
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            let sentinel = outside.appendingPathComponent("sentinel")
            try Data([9]).write(to: sentinel)
            try setFixtureQuarantine(sentinel, value: "0081;12345678;ExternalSentinel;")
            let originalMetadata = try attachmentQuarantineValue(sentinel)
            let target = moved.appendingPathComponent("file")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sentinel)
            let started = Date()
            if scripted {
                _ = try destination.saveUsingScript({ path in
                    try Data([4]).write(to: URL(fileURLWithPath: path))
                    return "Attachment saved"
                }, allowEmpty: false)
            } else {
                _ = try destination.publish(Data([4]))
            }
            XCTAssertEqual(try Data(contentsOf: target), Data([4]))
            try assertFreshAttachmentQuarantine(target, since: started)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([9]))
            XCTAssertEqual(try attachmentQuarantineValue(sentinel), originalMetadata)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path + "/file"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["file"])
        }
    }

    func testMarkdownExportDoesNotAcquireAttachmentQuarantine() throws {
        let root = try fixtureRoot(), target = root.appendingPathComponent("export.md")
        try RaceFreeFileWriter.writeFile(rootDir: root.path, relativeDirComponents: [],
                                        filename: "export.md", data: Data("export".utf8))
        XCTAssertEqual(try Data(contentsOf: target), Data("export".utf8))
        XCTAssertNil(try attachmentQuarantineValue(target))
    }
}

/// Shared by synthetic and explicitly opted-in native Mail tests.
func attachmentQuarantineValue(_ url: URL) throws -> String? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = buffer.withUnsafeMutableBytes { bytes in
        fgetxattr(fd, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, 0)
    }
    if count < 0 {
        if errno == ENOATTR { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return String(decoding: buffer.prefix(count), as: UTF8.self)
}

func assertFreshAttachmentQuarantine(_ url: URL, since started: Date,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
    let raw = try XCTUnwrap(attachmentQuarantineValue(url), "published attachment lacks quarantine", file: file, line: line)
    let fields = raw.split(separator: ";", omittingEmptySubsequences: false)
    XCTAssertEqual(fields.count, 4, file: file, line: line)
    guard fields.count == 4 else { return }
    XCTAssertEqual(fields[0], "0081", file: file, line: line)
    let timestamp = try XCTUnwrap(UInt64(fields[1], radix: 16), file: file, line: line)
    XCTAssertGreaterThanOrEqual(TimeInterval(timestamp), floor(started.timeIntervalSince1970), file: file, line: line)
    XCTAssertLessThanOrEqual(TimeInterval(timestamp), Date().timeIntervalSince1970, file: file, line: line)
    XCTAssertEqual(fields[2], "CheAppleMailMCP", file: file, line: line)
    XCTAssertEqual(fields[3], "", "no fabricated quarantine database event", file: file, line: line)
    let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
    XCTAssertNotNil(values.quarantineProperties, "Foundation must recognize the marker", file: file, line: line)
}

private func setFixtureQuarantine(_ url: URL, value: String) throws {
    let data = Data(value.utf8)
    let result = data.withUnsafeBytes { bytes in
        setxattr(url.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, 0)
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

func printAttachmentXattrs(_ url: URL, label: String) throws {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    process.arguments = ["-l", url.path]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    print("\(label), xattr -l:\n\(String(decoding: data, as: UTF8.self))")
}
