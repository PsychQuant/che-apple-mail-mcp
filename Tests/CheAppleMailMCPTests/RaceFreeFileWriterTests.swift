import XCTest
import Foundation
@testable import CheAppleMailMCP

/// #200: the export write path descends from a validated dir fd with
/// `openat`/`mkdirat` + `O_NOFOLLOW` and writes with `O_CREAT|O_EXCL|O_NOFOLLOW`,
/// so a symlink planted in the validate→write window can't redirect the write.
/// A live race isn't deterministically reproducible — these assert the mechanism.
final class RaceFreeFileWriterTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "idd200-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testNormalNestedWrite_succeeds() throws {
        let rootFd = try RaceFreeFileWriter.openValidatedRootDir(root)
        defer { close(rootFd) }
        let leaf = try RaceFreeFileWriter.descendCreatingDirs(rootFd: rootFd, components: ["attachments", "stem"])
        defer { close(leaf) }
        try RaceFreeFileWriter.writeFileAtomicNoFollow(dirFd: leaf, name: "f.txt", data: Data("hi".utf8))

        let written = root + "/attachments/stem/f.txt"
        XCTAssertEqual(try String(contentsOfFile: written, encoding: .utf8), "hi")
    }

    func testDescend_throughSymlinkedComponent_throwsSymlinkComponent() throws {
        // Plant `root/attachments` as a symlink pointing OUTSIDE root — the exact
        // TOCTOU swap. Descent must refuse it (O_NOFOLLOW → ELOOP).
        let elsewhere = NSTemporaryDirectory() + "idd200-elsewhere-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: elsewhere) }
        try FileManager.default.createSymbolicLink(atPath: root + "/attachments", withDestinationPath: elsewhere)

        let rootFd = try RaceFreeFileWriter.openValidatedRootDir(root)
        defer { close(rootFd) }
        XCTAssertThrowsError(
            try RaceFreeFileWriter.descendCreatingDirs(rootFd: rootFd, components: ["attachments", "stem"])
        ) { error in
            guard case RaceFreeWriteError.symlinkComponent = error else {
                return XCTFail("expected symlinkComponent, got \(error)")
            }
        }
    }

    func testWrite_existingFile_overwritesAtomically() throws {
        // Re-export must work: a second write to the same name replaces the file
        // (atomic rename), preserving the prior `.atomic` overwrite semantics.
        let rootFd = try RaceFreeFileWriter.openValidatedRootDir(root)
        defer { close(rootFd) }
        try RaceFreeFileWriter.writeFileAtomicNoFollow(dirFd: rootFd, name: "x.md", data: Data("first".utf8))
        try RaceFreeFileWriter.writeFileAtomicNoFollow(dirFd: rootFd, name: "x.md", data: Data("second".utf8))
        XCTAssertEqual(try String(contentsOfFile: root + "/x.md", encoding: .utf8), "second")
    }

    func testWrite_symlinkedTarget_replacedNotFollowed() throws {
        // A symlink planted at the target filename must be REPLACED with a real
        // file, never followed — the symlink's target must not be written.
        let outside = NSTemporaryDirectory() + "idd200-victim-\(UUID().uuidString).txt"
        try FileManager.default.createSymbolicLink(atPath: root + "/y.md", withDestinationPath: outside)
        let rootFd = try RaceFreeFileWriter.openValidatedRootDir(root)
        defer { close(rootFd) }
        try RaceFreeFileWriter.writeFileAtomicNoFollow(dirFd: rootFd, name: "y.md", data: Data("payload".utf8))

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside),
                       "the symlink target must NOT be written (no follow)")
        // y.md is now a real file with the payload (the symlink was replaced).
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/y.md", isDirectory: &isDir))
        let attrs = try FileManager.default.attributesOfItem(atPath: root + "/y.md")
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular,
                       "y.md must be a regular file, not the planted symlink")
        XCTAssertEqual(try String(contentsOfFile: root + "/y.md", encoding: .utf8), "payload")
    }
    // MARK: - #342: opt-in exclusive rename (ask the filesystem, not a prediction)

    /// Default (`failIfExists: false`) keeps create-or-REPLACE — every existing
    /// caller, including the attachment write, depends on it.
    func testWriteFile_defaultStillReplacesExistingFile() throws {
        let dir = URL(fileURLWithPath: root)
        let target = dir.appendingPathComponent("a.md")
        try "OLD".write(to: target, atomically: true, encoding: .utf8)

        try RaceFreeFileWriter.writeFile(
            rootDir: dir.path, relativeDirComponents: [], filename: "a.md",
            data: Data("NEW".utf8))

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "NEW",
                       "default semantics must stay create-or-replace (#342)")
    }

    /// Opt-in refuses rather than clobbering, and leaves the existing file
    /// byte-for-byte intact — the property that turns a guard miss from silent
    /// data loss into a reportable error.
    func testWriteFile_failIfExists_refusesAndLeavesExistingFileIntact() throws {
        let dir = URL(fileURLWithPath: root)
        let target = dir.appendingPathComponent("a.md")
        try "PRECIOUS".write(to: target, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try RaceFreeFileWriter.writeFile(
            rootDir: dir.path, relativeDirComponents: [], filename: "a.md",
            data: Data("CLOBBER".utf8), failIfExists: true)) { error in
            guard case RaceFreeWriteError.destinationExists(let name) = error else {
                return XCTFail("expected destinationExists, got \(error)")
            }
            XCTAssertEqual(name, "a.md")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "PRECIOUS",
                       "the refused write must not have touched the existing file (#342)")
    }

    /// Opt-in on a free name is an ordinary successful write.
    func testWriteFile_failIfExists_succeedsOnFreshName() throws {
        let dir = URL(fileURLWithPath: root)
        try RaceFreeFileWriter.writeFile(
            rootDir: dir.path, relativeDirComponents: [], filename: "fresh.md",
            data: Data("OK".utf8), failIfExists: true)
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("fresh.md"), encoding: .utf8), "OK")
    }

    /// A refused write must not leave its sibling temp behind.
    func testWriteFile_failIfExists_cleansUpTempOnRefusal() throws {
        let dir = URL(fileURLWithPath: root)
        try "X".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        _ = try? RaceFreeFileWriter.writeFile(
            rootDir: dir.path, relativeDirComponents: [], filename: "a.md",
            data: Data("Y".utf8), failIfExists: true)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".idd200.tmp") }
        XCTAssertTrue(leftovers.isEmpty, "temp must be cleaned up on refusal, found: \(leftovers)")
    }

}
