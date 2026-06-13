import XCTest
import Foundation
@testable import CheAppleMailMCP

final class AllowedRootsValidatorTests: XCTestCase {

    private let validator = AllowedRootsValidator()

    // MARK: - Accept cases

    func testValidate_underHome_accepts() throws {
        let target = NSHomeDirectory() + "/idd193-export-\(UUID().uuidString)"
        let result = try validator.validate(target, allowedRoots: [])
        XCTAssertTrue(
            result.path.hasPrefix(AllowedRootsValidator.canonicalize(NSHomeDirectory()).path),
            "a path under home should be accepted and returned canonicalized"
        )
    }

    func testValidate_underConfiguredAllowedRoot_accepts() throws {
        // A temp root NOT under home — accepted only because it is an
        // explicitly configured allowed root.
        let root = NSTemporaryDirectory() + "idd193-root-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = try validator.validate(root + "/sub/dir", allowedRoots: [root])
        let canonRoot = AllowedRootsValidator.canonicalize(root).path
        XCTAssertTrue(result.path.hasPrefix(canonRoot),
                      "a path under a configured allowed root should be accepted")
    }

    func testValidate_nonexistentNestedUnderHome_accepts() throws {
        // validate() must not require the directory to exist (caller mkdir -p's it).
        let target = NSHomeDirectory() + "/idd193-\(UUID().uuidString)/a/b/c"
        XCTAssertNoThrow(try validator.validate(target, allowedRoots: []))
    }

    // MARK: - Reject cases

    func testValidate_outsideAllAllowedRoots_rejectsEscape() {
        // Temp dir is not under home and not a configured root → escape.
        let target = NSTemporaryDirectory() + "idd193-outside-\(UUID().uuidString)"
        XCTAssertThrowsError(try validator.validate(target, allowedRoots: [])) { error in
            guard case AllowedRootsError.escapesAllowedRoots = error else {
                return XCTFail("expected escapesAllowedRoots, got \(error)")
            }
        }
    }

    func testValidate_dotDotEscapeToSystem_rejects() {
        // ~/../../../../etc/passwd collapses to /etc/passwd → denied.
        let target = NSHomeDirectory() + "/../../../../etc/passwd"
        XCTAssertThrowsError(try validator.validate(target, allowedRoots: [])) { error in
            guard case AllowedRootsError.systemPath = error else {
                return XCTFail("expected systemPath, got \(error)")
            }
        }
    }

    func testValidate_systemDenylistOverridesAllowedRoot() {
        // Even if /etc is mistakenly configured as an allowed root, the
        // system denylist (belt-and-suspenders) must still refuse it.
        XCTAssertThrowsError(try validator.validate("/etc/cron.d", allowedRoots: ["/etc"])) { error in
            guard case AllowedRootsError.systemPath = error else {
                return XCTFail("expected systemPath (denylist precedence), got \(error)")
            }
        }
    }

    func testValidate_symlinkEscape_rejects() throws {
        // A symlink under home pointing at /etc must be resolved before the
        // root check, so writing "through" it is refused.
        let linkPath = NSHomeDirectory() + "/idd193-evil-link-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/etc")
        defer { try? FileManager.default.removeItem(atPath: linkPath) }

        XCTAssertThrowsError(try validator.validate(linkPath + "/sub", allowedRoots: [])) { error in
            guard case AllowedRootsError.systemPath = error else {
                return XCTFail("expected systemPath after symlink resolution, got \(error)")
            }
        }
    }
}
