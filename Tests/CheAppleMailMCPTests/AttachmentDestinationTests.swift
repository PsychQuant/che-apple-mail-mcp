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


    // MARK: - #402 verify

    /// Data.write (both tiers before #402) and export's writer give 0644; the
    /// publisher's 0600 made every saved attachment owner-only.
    func testPublishedFileHasTheModeTheTiersUsedBefore() throws {
        let root = try fixtureRoot()
        let path = root.path + "/report.pdf"
        // A known umask for this test only, restored afterwards: under 077 the
        // 0600 regression would be invisible (#402 verify).
        let previous = umask(0o022)
        defer { umask(previous) }
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([1]))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o644)
    }

    /// An overwrite keeps the existing file's mode: a file the user made private
    /// must not become readable by others when it is saved again.
    func testOverwriteKeepsTheExistingFilesMode() throws {
        let root = try fixtureRoot()
        let path = root.path + "/private.pdf"
        try Data([1]).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let previous = umask(0o022)
        defer { umask(previous) }
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([2, 3]))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([2, 3]))
    }

    /// A failure in the server's private stage is a stage error, not a
    /// destination error: neither another save_path nor an allowed root helps.
    func testAStageFailureIsNotReportedAsADestinationFailure() throws {
        let root = try fixtureRoot()
        let destination = try AttachmentDestination(savePath: root.path + "/out.pdf", allowedRoots: [root.path])
        XCTAssertThrowsError(try destination.saveUsingScript({ source in
            // A link where Mail's staged file should be: opened without following links.
            try FileManager.default.createSymbolicLink(atPath: source, withDestinationPath: root.path + "/elsewhere")
            return "Attachment saved to \(source)"
        }, allowEmpty: false)) { error in
            guard case AttachmentDestinationError.stage = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.hasPrefix("save_attachment: stage_failed:"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("destination_"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/out.pdf"))
    }

    /// As in export: a configured root that cannot be resolved matches nothing;
    /// it neither fails every save nor drops out (an empty list means all of home).
    func testAnUnresolvableRootDoesNotRejectAnotherRoot() throws {
        let good = try fixtureRoot(), locked = try fixtureRoot()
        let hidden = locked.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let unresolvable = hidden.appendingPathComponent("root").path
        XCTAssertNoThrow(try AttachmentDestination(savePath: good.path + "/a.pdf", allowedRoots: [unresolvable, good.path]))
        XCTAssertThrowsError(try AttachmentDestination(savePath: NSHomeDirectory() + "/idd402-not-created",
                                                       allowedRoots: [unresolvable]),
                             "an unresolvable root must not widen the policy to home")
    }

    /// A 0-byte Tier-1 read is a miss unless the caller attested an empty part.
    func testZeroByteTier1ReadIsPublishableOnlyUnderAllowEmpty() {
        XCTAssertFalse(AttachmentDestination.tier1BytesArePublishable(Data(), allowEmpty: false))
        XCTAssertTrue(AttachmentDestination.tier1BytesArePublishable(Data(), allowEmpty: true))
        XCTAssertTrue(AttachmentDestination.tier1BytesArePublishable(Data([1]), allowEmpty: false))
    }

    /// The temporary file is private while the bytes are written: replacing a
    /// 0600 file must never expose its new contents to other users mid-write.
    func testTheTemporaryFileIsPrivateWhileItIsWritten() throws {
        let root = try fixtureRoot()
        let previous = umask(0o022)
        defer { umask(previous) }
        try Data([1]).write(to: root.appendingPathComponent("private.pdf"))
        let dirFd = open(root.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(dirFd, 0)
        defer { close(dirFd) }
        var modeWhileWriting: mode_t = 0o777
        try RaceFreeFileWriter.withAtomicAttachmentFile(dirFd: dirFd, name: "private.pdf") { fd in
            var info = stat()
            XCTAssertEqual(fstat(fd, &info), 0)
            modeWhileWriting = info.st_mode & 0o777
        }
        XCTAssertEqual(modeWhileWriting & 0o077, 0, "group and others must not read the temporary file")
    }

    /// The sender's bytes never keep execute bits, even when they replace an
    /// executable file, and a new file follows the umask.
    func testPublishedFilesNeverKeepExecuteBitsAndFollowTheUmask() throws {
        let root = try fixtureRoot()
        let script = root.path + "/hook.sh"
        try Data([1]).write(to: URL(fileURLWithPath: script))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let previous = umask(0o077)
        defer { umask(previous) }
        _ = try AttachmentDestination(savePath: script, allowedRoots: [root.path]).publish(Data([2]))
        let replaced = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? Int)
        XCTAssertEqual(replaced & 0o777, 0o644, "the replaced file's read/write bits, without execute")
        let fresh = root.path + "/new.pdf"
        _ = try AttachmentDestination(savePath: fresh, allowedRoots: [root.path]).publish(Data([3]))
        let created = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fresh)[.posixPermissions] as? Int)
        XCTAssertEqual(created & 0o777, 0o600, "umask 077 gives a new file 0600")
    }

    /// A permission error before authorization is a write problem only for a
    /// path the policy accepts as written; otherwise it is a rejection.
    func testAPermissionErrorBeforeAuthorizationDependsOnThePolicy() throws {
        let root = try fixtureRoot(), outside = try fixtureRoot()
        for base in [root, outside] {
            let locked = base.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: locked.appendingPathComponent("inner"), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        }
        XCTAssertThrowsError(try AttachmentDestination(savePath: root.path + "/locked/inner/a.pdf", allowedRoots: [root.path])) { error in
            guard case AttachmentDestinationError.io = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try AttachmentDestination(savePath: outside.path + "/locked/inner/a.pdf", allowedRoots: [root.path])) { error in
            guard case AttachmentDestinationError.rejected = error else { return XCTFail("\(error)") }
        }
    }
}

