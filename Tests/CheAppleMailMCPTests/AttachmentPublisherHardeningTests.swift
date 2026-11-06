import XCTest
import Darwin
@testable import CheAppleMailMCP

/// #576 — four edge cases in the attachment publisher #402 added: search-only
/// ancestors, rejection text that worked as a filesystem probe, temporaries a
/// kill leaves behind, and ACLs a temporary inherits from its folder.
final class AttachmentPublisherHardeningTests: XCTestCase {

    private func fixtureRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("idd576-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // `/var/folders` is a link to `/private/var/folders`; the walk uses the real path.
        let root = URL(fileURLWithPath: AllowedRootsValidator.canonicalize(raw.path).path)
        addTeardownBlock {
            // A search-only child would stop the removal.
            if let items = FileManager.default.enumerator(atPath: root.path) {
                for case let item as String in items { chmod(root.appendingPathComponent(item).path, 0o755) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeSearchOnly(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(url.path, 0o311), 0)
        addTeardownBlock { chmod(url.path, 0o755) }
    }

    // MARK: - 1. search-only ancestors

    func testASearchOnlyAncestorDoesNotStopASave() throws {
        let root = try fixtureRoot()
        let ancestor = root.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: ancestor.appendingPathComponent("existing"), withIntermediateDirectories: true)
        try makeSearchOnly(ancestor)

        let path = ancestor.appendingPathComponent("existing/new/report.pdf").path
        let destination = try AttachmentDestination(savePath: path, allowedRoots: [root.path])
        XCTAssertEqual(try destination.publish(Data([1, 2, 3])), "Attachment saved to \(path) (3 bytes)")
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data([1, 2, 3]))
    }

    func testASearchOnlyDestinationDirectoryAcceptsAFile() throws {
        let root = try fixtureRoot()
        let folder = root.appendingPathComponent("dropbox")
        try makeSearchOnly(folder)
        let path = folder.appendingPathComponent("report.pdf").path
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([9]))
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data([9]))
    }

    func testAnAncestorWithoutWritePermissionStillWalksWhenTheChildExists() throws {
        let root = try fixtureRoot()
        let ancestor = root.appendingPathComponent("readonly")
        let inner = ancestor.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(ancestor.path, 0o111), 0)
        addTeardownBlock { chmod(ancestor.path, 0o755) }
        let path = inner.appendingPathComponent("report.pdf").path
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([4]))
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data([4]))
    }

    func testTheExportWriterWalksASearchOnlyDirectory() throws {
        let root = try fixtureRoot()
        let folder = root.appendingPathComponent("archive")
        try makeSearchOnly(folder)
        try RaceFreeFileWriter.writeFile(rootDir: folder.path, relativeDirComponents: ["2026"],
                                         filename: "note.md", data: Data("x".utf8))
        XCTAssertEqual(FileManager.default.contents(atPath: folder.path + "/2026/note.md"), Data("x".utf8))
    }

    func testAPlantedSymlinkStillFailsTheSearchOnlyWalk() throws {
        let root = try fixtureRoot()
        let target = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.path + "/link", withDestinationPath: target.path)
        let rootFd = try RaceFreeFileWriter.openValidatedRootDir(root.path)
        defer { close(rootFd) }
        XCTAssertThrowsError(try RaceFreeFileWriter.descendCreatingDirs(rootFd: rootFd, components: ["link"])) { error in
            XCTAssertEqual(error as? RaceFreeWriteError, .symlinkComponent(component: "link"))
        }
    }

    func testTheWalkFallsBackWhenAFilesystemRefusesSearchOnlyOpens() {
        var flags: [Int32] = []
        let fd = RaceFreeFileWriter.openDirectoryForWalk { value in
            flags.append(value)
            if flags.count == 1 { errno = ENOTSUP; return -1 }
            return 7
        }
        XCTAssertEqual(fd, 7)
        XCTAssertEqual(flags.count, 2)
        XCTAssertEqual(flags[1] & O_NOFOLLOW, O_NOFOLLOW, "the fallback keeps no-follow")
    }

    func testAPermissionFailureIsNotRetriedWithReadAccess() {
        var calls = 0
        let fd = RaceFreeFileWriter.openDirectoryForWalk { _ in calls += 1; errno = EACCES; return -1 }
        XCTAssertEqual(fd, -1)
        XCTAssertEqual(calls, 1)
    }

    // MARK: - 2. rejection text

    private func rejection(_ path: String, roots: [String]) -> String? {
        do {
            _ = try AttachmentDestination(savePath: path, allowedRoots: roots)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testARejectionDoesNotSayWhereASymlinkPoints() throws {
        let root = try fixtureRoot()
        let secret = root.deletingLastPathComponent().appendingPathComponent("idd576-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: secret) }
        try FileManager.default.createSymbolicLink(atPath: root.path + "/link", withDestinationPath: secret.path)

        let message = try XCTUnwrap(rejection(root.path + "/link/file.pdf", roots: [root.path]))
        XCTAssertTrue(message.contains("is outside the permitted destination policy"), message)
        XCTAssertFalse(message.contains(secret.lastPathComponent), message)
        XCTAssertFalse(message.contains("escapesAllowedRoots"), message)
        XCTAssertFalse(message.contains("path:"), message)
    }

    func testRejectionsOfDifferentKindsAreWordedAlike() throws {
        let root = try fixtureRoot()
        let denied = NSHomeDirectory() + "/.ssh/idd576-file"
        let system = "/private/etc/idd576-file"
        let outside = root.deletingLastPathComponent().path + "/idd576-absent-\(UUID().uuidString)/file"
        let messages = [denied, system, outside].map { rejection($0, roots: [root.path]) }
        XCTAssertEqual(Set(messages).count, 1, "\(messages)")
    }

    func testAResolutionFailureOutsideThePolicySaysNothingAboutWhatIsThere() throws {
        let root = try fixtureRoot()
        // `/private/etc/hosts` is a file, so this fails to resolve with ENOTDIR.
        let throughAFile = rejection("/private/etc/hosts/idd576-file", roots: [root.path])
        let absent = rejection("/private/etc/idd576-absent/idd576-file", roots: [root.path])
        XCTAssertNotNil(throughAFile)
        XCTAssertEqual(throughAFile, absent, "a caller must not learn which of the two paths exists")
    }

    func testAResolutionFailureInsideThePolicyKeepsItsReason() throws {
        let root = try fixtureRoot()
        try Data("x".utf8).write(to: root.appendingPathComponent("a-file"))
        let message = try XCTUnwrap(rejection(root.path + "/a-file/sub/report.pdf", roots: [root.path]))
        XCTAssertTrue(message.contains("a component is a file"), message)
    }

    // MARK: - 3. temporaries after a kill

    func testTemporaryNamesCarryThePidAndRoundTrip() throws {
        let name = RaceFreeFileWriter.temporaryName(pid: 4242, host: "abcd0123")
        XCTAssertTrue(name.hasPrefix(".attachment-4242-abcd0123-"), name)
        let parsed = RaceFreeFileWriter.parseTemporaryName(name)
        XCTAssertTrue(parsed.isTemporary)
        XCTAssertEqual(parsed.pid, 4242)
        XCTAssertEqual(parsed.host, "abcd0123")
        XCTAssertNotNil(RaceFreeFileWriter.hostTag, "this Mac has a host id")
        XCTAssertNotEqual(RaceFreeFileWriter.temporaryName(), RaceFreeFileWriter.temporaryName(),
                          "unique per save, so concurrent saves cannot touch each other's file (#402)")

        let legacy = ".attachment-\(UUID().uuidString).tmp"
        XCTAssertTrue(RaceFreeFileWriter.parseTemporaryName(legacy).isTemporary)
        XCTAssertNil(RaceFreeFileWriter.parseTemporaryName(legacy).pid)

        for other in [".attachment-notes.tmp", ".attachment-12-notes.tmp", ".attachment--h-\(UUID().uuidString).tmp",
                      ".attachment-0-h-\(UUID().uuidString).tmp", ".attachment-1--\(UUID().uuidString).tmp",
                      ".attachment-1-\(UUID().uuidString).tmp", "attachment-1-h-\(UUID().uuidString).tmp",
                      ".attachment-1-h-\(UUID().uuidString).pdf", ".attachment-.tmp", "report.pdf"] {
            XCTAssertFalse(RaceFreeFileWriter.parseTemporaryName(other).isTemporary, other)
        }
    }

    private func sweep(_ root: URL, alive: Set<Int32>, now: Date = Date(), thisHost: String? = "here") throws {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        RaceFreeFileWriter.sweepStaleTemporaries(dirFd: fd, now: now, thisHost: thisHost,
                                                 isAlive: { alive.contains($0) })
    }

    private func touch(_ url: URL, modified: Date? = nil) throws {
        try Data("partial".utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    func testASweepRemovesADeadOwnersFileAndKeepsALiveOne() throws {
        let root = try fixtureRoot()
        let dead = root.appendingPathComponent(RaceFreeFileWriter.temporaryName(pid: 111, host: "here"))
        let live = root.appendingPathComponent(RaceFreeFileWriter.temporaryName(pid: 222, host: "here"))
        let report = root.appendingPathComponent("report.pdf")
        let lookalike = root.appendingPathComponent(".attachment-notes.tmp")
        for url in [dead, live, report, lookalike] { try touch(url) }

        try sweep(root, alive: [222])
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(names, [live.lastPathComponent, "report.pdf", ".attachment-notes.tmp"])
    }

    func testAPidFromAnotherMacIsNotJudgedByThisMacsProcessTable() throws {
        // A shared or synced folder: that pid may be running over there.
        let root = try fixtureRoot()
        let elsewhere = root.appendingPathComponent(RaceFreeFileWriter.temporaryName(pid: 111, host: "there"))
        let oldElsewhere = root.appendingPathComponent(RaceFreeFileWriter.temporaryName(pid: 112, host: "there"))
        try touch(elsewhere)
        try touch(oldElsewhere, modified: Date().addingTimeInterval(-RaceFreeFileWriter.staleTemporaryAge - 60))

        try sweep(root, alive: [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [elsewhere.lastPathComponent],
                       "only age removes another Mac's file")

        try sweep(root, alive: [], thisHost: nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [elsewhere.lastPathComponent],
                       "without a host id nothing counts as local")
    }

    func testASweepRemovesAnOldFileWhoseOwnerLooksAliveOrIsUnknown() throws {
        // A pid can be reused, and the form before #576 named no owner.
        let root = try fixtureRoot()
        let old = Date().addingTimeInterval(-RaceFreeFileWriter.staleTemporaryAge - 60)
        let reused = root.appendingPathComponent(RaceFreeFileWriter.temporaryName(pid: 333, host: "here"))
        let legacyOld = root.appendingPathComponent(".attachment-\(UUID().uuidString).tmp")
        let legacyNew = root.appendingPathComponent(".attachment-\(UUID().uuidString).tmp")
        try touch(reused, modified: old)
        try touch(legacyOld, modified: old)
        try touch(legacyNew)

        try sweep(root, alive: [333])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), [legacyNew.lastPathComponent],
                       "a recent file of unknown owner may belong to a running older server")
    }

    func testASweepLeavesLinksAndDirectoriesAlone() throws {
        let root = try fixtureRoot()
        let target = root.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        let link = root.appendingPathComponent(RaceFreeFileWriter.temporaryName(pid: 444, host: "here"))
        let folder = root.appendingPathComponent(RaceFreeFileWriter.temporaryName(pid: 445, host: "here"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try sweep(root, alive: [])
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(Set(names), ["target.txt", link.lastPathComponent, folder.lastPathComponent])
    }

    func testPublishingClearsWhatAKilledServerLeft() throws {
        let root = try fixtureRoot()
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let leftover = root.appendingPathComponent(RaceFreeFileWriter.temporaryName(pid: finished.processIdentifier))
        try touch(leftover)

        let path = root.appendingPathComponent("report.pdf").path
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([1]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["report.pdf"])
    }

    func testPublishingLeavesAnotherSavesFileAlone() throws {
        let root = try fixtureRoot()
        // This process is alive, as a concurrent save in it would be.
        let sibling = root.appendingPathComponent(RaceFreeFileWriter.temporaryName())
        try touch(sibling)
        let path = root.appendingPathComponent("report.pdf").path
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    // MARK: - 4. inherited ACLs

    private func hasExtendedACL(_ path: String) -> Bool {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }

    private func addInheritableReadEntry(to path: String) throws {
        let chmodTool = Process()
        chmodTool.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodTool.arguments = ["+a", "everyone allow read,file_inherit", path]
        try chmodTool.run()
        chmodTool.waitUntilExit()
        XCTAssertEqual(chmodTool.terminationStatus, 0)
    }

    func testAPublishedFileDoesNotKeepAnInheritedACL() throws {
        let root = try fixtureRoot()
        try addInheritableReadEntry(to: root.path)
        // The control: this folder does hand its entry to a new file.
        let control = root.appendingPathComponent("control.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: control.path, contents: Data("x".utf8)))
        XCTAssertTrue(hasExtendedACL(control.path), "the fixture must really inherit")

        let path = root.appendingPathComponent("report.pdf").path
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([1, 2]))
        XCTAssertFalse(hasExtendedACL(path))
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data([1, 2]))
    }

    func testAReplacedFilesACLIsNotCarriedOver() throws {
        let root = try fixtureRoot()
        let path = root.appendingPathComponent("report.pdf").path
        try Data([1]).write(to: URL(fileURLWithPath: path))
        try addInheritableReadEntry(to: path)
        XCTAssertTrue(hasExtendedACL(path))
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([2]))
        XCTAssertFalse(hasExtendedACL(path))
    }

    func testAFolderWithoutACLsIsUnaffected() throws {
        let root = try fixtureRoot()
        let path = root.appendingPathComponent("report.pdf").path
        _ = try AttachmentDestination(savePath: path, allowedRoots: [root.path]).publish(Data([1]))
        XCTAssertFalse(hasExtendedACL(path))
    }
}
