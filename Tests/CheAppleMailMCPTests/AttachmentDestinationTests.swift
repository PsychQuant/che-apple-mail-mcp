import XCTest
@testable import CheAppleMailMCP

final class AttachmentDestinationTests: XCTestCase {
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idd402-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testTraversalRejectedBeforeMkdirAndNormalOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idd402-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AttachmentDestination(savePath: root.path + "/new/../escape", allowedRoots: [root.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let path = root.path + "/new/report.pdf"
        let destination = try AttachmentDestination(savePath: path, allowedRoots: [root.path])
        XCTAssertEqual(try destination.publish(Data([1, 2])), "Attachment saved to \(path) (2 bytes)")
        _ = try destination.publish(Data([3]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([3]))
    }
    func testMalformedAndTraversalFormsDoNotCreateParents() throws {
        let root = try fixtureRoot()
        for suffix in ["../escape", "new/../escape", "./file", "new//file", "new/", "x\\y", "x\u{0}y", "x\ny", "x\u{7f}y"] {
            XCTAssertThrowsError(try AttachmentDestination(savePath: root.path + "/" + suffix, allowedRoots: [root.path])) { error in
                guard case AttachmentDestinationError.rejected = error else { return XCTFail("\(error)") }
            }
        }
        for path in ["", "relative.pdf", "~/Documents/a", "/"] {
            XCTAssertThrowsError(try AttachmentDestination(savePath: path, allowedRoots: [root.path]))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testLiteralPercentAndUnicodeNamesAreNotDecoded() throws {
        let root = try fixtureRoot()
        for name in ["%2e%2e%2fescape", "報告「附件」.pdf", "a%00b", "全形／斜線.pdf"] {
            let destination = try AttachmentDestination(savePath: root.path + "/" + name, allowedRoots: [root.path])
            _ = try destination.publish(Data([7]))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data([7]))
        }
    }

    func testRootsAndDenylistCoverTheLeafAndCannotBeOverridden() throws {
        let root = try fixtureRoot()
        let outside = root.path + "-outside/new/file"
        XCTAssertThrowsError(try AttachmentDestination(savePath: outside, allowedRoots: [root.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "-outside"))
        for path in [NSHomeDirectory() + "/.zshrc", NSHomeDirectory() + "/.SSH/idd402-file", "/private/etc/idd402-file"] {
            XCTAssertThrowsError(try AttachmentDestination(savePath: path, allowedRoots: [URL(fileURLWithPath: path).deletingLastPathComponent().path]))
        }
        XCTAssertThrowsError(try AttachmentDestination(savePath: NSHomeDirectory() + "/idd402-file", allowedRoots: [root.path]))
        XCTAssertThrowsError(try AttachmentDestination(savePath: root.path + "/file", allowedRoots: []))
    }

    func testExistingSymlinkEscapeRejectedAndInRootAliasPreserved() throws {
        let root = try fixtureRoot(), outside = try fixtureRoot()
        let target = outside.appendingPathComponent("target")
        try Data([9]).write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AttachmentDestination(savePath: link.path, allowedRoots: [root.path]))
        XCTAssertEqual(try Data(contentsOf: target), Data([9]))
        try FileManager.default.removeItem(at: link)
        let inside = root.appendingPathComponent("inside")
        try Data([1]).write(to: inside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        _ = try AttachmentDestination(savePath: link.path, allowedRoots: [root.path]).publish(Data([2]))
        XCTAssertEqual(try Data(contentsOf: inside), Data([2]))
    }

    func testAncestorSwapBetweenValidationAndOpenCannotEscape() throws {
        let root = try fixtureRoot(), outside = try fixtureRoot()
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AttachmentDestination(savePath: parent.path + "/child/file", allowedRoots: [root.path], beforeOpen: {
            try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testPinnedParentAndLateLeafSwapNeverFollowOutsideLinks() throws {
        let root = try fixtureRoot(), outside = try fixtureRoot()
        let parent = root.appendingPathComponent("parent"), moved = root.appendingPathComponent("moved")
        let destination = try AttachmentDestination(savePath: parent.path + "/file", allowedRoots: [root.path])
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data([9]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: moved.appendingPathComponent("file"), withDestinationURL: sentinel)
        _ = try destination.publish(Data([4]))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("file")), Data([4]))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path + "/file"))
    }

    func testEmptyUsesSamePublisherAndRequiresOverride() throws {
        let root = try fixtureRoot()
        let destination = try AttachmentDestination(savePath: root.path + "/file", allowedRoots: [root.path])
        _ = try destination.publish(Data([1]))
        XCTAssertThrowsError(try destination.publish(Data()))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data([1]))
        XCTAssertTrue(try destination.publish(Data(), allowEmpty: true).contains("allow_empty"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")).count, 0)
    }

    func testPrivateStageNeverUsesExistingDestinationAndCleansEveryExit() throws {
        let root = try fixtureRoot()
        let target = root.appendingPathComponent("file")
        try Data([9]).write(to: target)
        let destination = try AttachmentDestination(savePath: target.path, allowedRoots: [root.path])
        var paths: [String] = []
        for mode in ["missing", "failure", "negative", "success"] {
            do {
                let result = try destination.saveUsingScript({ path in
                    paths.append(path)
                    XCTAssertNotEqual(path, target.path)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
                    let permissions = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
                    XCTAssertEqual(permissions.intValue & 0o777, 0o700)
                    if mode == "failure" { throw MailError.scriptFailed(message: "fixture", code: -1728) }
                    if mode == "negative" { return "Attachment not found" }
                    if mode == "success" { try Data([3, 4]).write(to: URL(fileURLWithPath: path)) }
                    return "Attachment saved to \(path)"
                }, allowEmpty: true)
                XCTAssertTrue(mode == "negative" || mode == "success")
                if mode == "success" { XCTAssertEqual(result, "Attachment saved to \(target.path) (2 bytes)") }
            } catch {
                XCTAssertTrue(mode == "missing" || mode == "failure", "\(error)")
            }
            if mode != "success" { XCTAssertEqual(try Data(contentsOf: target), Data([9])) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: paths.last!).deletingLastPathComponent().path))
        }
        XCTAssertEqual(Set(paths).count, paths.count)
    }

    func testStageSymlinkDirectoryAndFifoAreTerminalEvenWithAllowEmpty() throws {
        let root = try fixtureRoot()
        let sentinel = root.appendingPathComponent("sentinel")
        try Data([9]).write(to: sentinel)
        let destination = try AttachmentDestination(savePath: root.path + "/file", allowedRoots: [root.path])
        for kind in ["symlink", "directory", "fifo"] {
            XCTAssertThrowsError(try destination.saveUsingScript({ path in
                switch kind {
                case "symlink": try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: sentinel.path)
                case "directory": try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                default: XCTAssertEqual(mkfifo(path, 0o600), 0)
                }
                return "Attachment saved to \(path)"
            }, allowEmpty: true))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/file"))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([9]))
    }

    func testLargeStageStreamsAndReportsSize() throws {
        let root = try fixtureRoot()
        let target = root.appendingPathComponent("large")
        let destination = try AttachmentDestination(savePath: target.path, allowedRoots: [root.path])
        let size: UInt64 = 101 * 1024 * 1024
        let receipt = try destination.saveUsingScript({ path in
            FileManager.default.createFile(atPath: path, contents: Data([7]))
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? file.close() }
            try file.truncate(atOffset: size)
            try file.seek(toOffset: size - 1)
            try file.write(contentsOf: Data([8]))
            return "Attachment saved to \(path)"
        }, allowEmpty: false)
        XCTAssertTrue(receipt.hasSuffix("(\(size) bytes)"))
        let file = try FileHandle(forReadingFrom: target)
        defer { try? file.close() }
        XCTAssertEqual(try file.read(upToCount: 1), Data([7]))
        try file.seek(toOffset: size - 1)
        XCTAssertEqual(try file.read(upToCount: 1), Data([8]))
    }

    func testPublicationFailurePreservesTargetAndCleansTemporaryFiles() throws {
        let root = try fixtureRoot(), target = root.appendingPathComponent("directory")
        let destination = try AttachmentDestination(savePath: target.path, allowedRoots: [root.path])
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try destination.publish(Data([1]))) { error in
            guard case AttachmentDestinationError.io = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["directory"])
    }

    func testConcurrentSavesPublishWholeFilesWithoutSharedTemps() throws {
        let root = try fixtureRoot()
        let destination = try AttachmentDestination(savePath: root.path + "/file", allowedRoots: [root.path])
        let lock = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do { _ = try destination.publish(Data(repeating: UInt8(index), count: 128 * 1024)) }
            catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let bytes = try Data(contentsOf: root.appendingPathComponent("file"))
        XCTAssertEqual(bytes.count, 128 * 1024)
        XCTAssertEqual(Set(bytes).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["file"])
    }

    func testOutsideLeafSwapBetweenResolutionAndAuthorizationIsRejected() throws {
        let allowed = try fixtureRoot(), outside = try fixtureRoot()
        let target = allowed.appendingPathComponent("existing")
        try Data([9]).write(to: target)
        let path = outside.appendingPathComponent("file")
        XCTAssertThrowsError(try AttachmentDestination(savePath: path.path, allowedRoots: [allowed.path], beforeValidation: {
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        }).publish(Data([1])))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data([9]))
    }

}
