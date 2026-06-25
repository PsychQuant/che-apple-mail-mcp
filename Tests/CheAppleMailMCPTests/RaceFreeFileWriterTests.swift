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
}
