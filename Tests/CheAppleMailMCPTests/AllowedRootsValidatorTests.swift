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

    // MARK: - #197 home-relative denylist (always applies, defense-in-depth)

    func testValidate_homeLibraryLaunchAgents_denied() {
        // ~/Library/LaunchAgents — the macOS persistence target — must be refused
        // even though it is under home.
        let target = NSHomeDirectory() + "/Library/LaunchAgents/evil.plist"
        XCTAssertThrowsError(try validator.validate(target, allowedRoots: [])) { error in
            guard case AllowedRootsError.deniedHomePath = error else {
                return XCTFail("expected deniedHomePath for ~/Library, got \(error)")
            }
        }
    }

    func testValidate_homeSsh_denied() {
        let target = NSHomeDirectory() + "/.ssh/authorized_keys"
        XCTAssertThrowsError(try validator.validate(target, allowedRoots: [])) { error in
            guard case AllowedRootsError.deniedHomePath = error else {
                return XCTFail("expected deniedHomePath for ~/.ssh, got \(error)")
            }
        }
    }

    func testValidate_homeConfig_denied() {
        let target = NSHomeDirectory() + "/.config/git"
        XCTAssertThrowsError(try validator.validate(target, allowedRoots: [])) { error in
            guard case AllowedRootsError.deniedHomePath = error else {
                return XCTFail("expected deniedHomePath for ~/.config, got \(error)")
            }
        }
    }

    func testValidate_homeBin_denied() {
        // ~/bin — where wrapped MCP binaries live (code-exec target).
        let target = NSHomeDirectory() + "/bin/wrapped-binary"
        XCTAssertThrowsError(try validator.validate(target, allowedRoots: [])) { error in
            guard case AllowedRootsError.deniedHomePath = error else {
                return XCTFail("expected deniedHomePath for ~/bin, got \(error)")
            }
        }
    }

    func testValidate_dotDotIntoDeniedHomeDir_denied() {
        // ~/Documents/../Library/X collapses to ~/Library/X → denied (the denylist
        // runs on the canonical, ..-collapsed path).
        let target = NSHomeDirectory() + "/Documents/../Library/X"
        XCTAssertThrowsError(try validator.validate(target, allowedRoots: [])) { error in
            guard case AllowedRootsError.deniedHomePath = error else {
                return XCTFail("expected deniedHomePath after ..-collapse, got \(error)")
            }
        }
    }

    func testValidate_normalHomeSubdir_stillAccepts() throws {
        // A non-denied home subdir must still work (backward-compat).
        let target = NSHomeDirectory() + "/Documents/MailArchive-\(UUID().uuidString)"
        XCTAssertNoThrow(try validator.validate(target, allowedRoots: []))
    }

    // MARK: - #197 strict allowlist (non-empty roots REPLACES home)

    func testValidate_strictMode_homeRejectedWhenRootsConfigured() throws {
        // With an explicit allowed root configured, home is no longer auto-allowed
        // (opt-in deny-by-default). The configured root still accepts.
        let root = NSTemporaryDirectory() + "idd197-strict-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let homeTarget = NSHomeDirectory() + "/Documents/x-\(UUID().uuidString)"
        XCTAssertThrowsError(try validator.validate(homeTarget, allowedRoots: [root])) { error in
            guard case AllowedRootsError.escapesAllowedRoots = error else {
                return XCTFail("strict mode: a home path must escape when roots are configured, got \(error)")
            }
        }
        XCTAssertNoThrow(try validator.validate(root + "/sub", allowedRoots: [root]))
    }

    // MARK: - #197 case-insensitive denylist (6-AI verify — Security + DA)

    /// On case-insensitive APFS `~/.KUBE` and `~/.kube` are the same directory.
    /// `canonicalize` only normalizes *existing* ancestors, so an absent denied
    /// dir keeps the attacker's case verbatim — a case-SENSITIVE match would let
    /// `~/.NETRC/x` (≡ `~/.netrc` on disk) bypass the denylist. These entries are
    /// credential *files* (very unlikely to exist as dirs), so the case is kept
    /// and the case-INSENSITIVE match is what denies them.
    func testValidate_caseVariantOfDeniedHomeDir_denied() {
        for variant in ["/.NETRC/x", "/.Git-Credentials/x", "/.PgPass/x", "/.SSH/authorized_keys"] {
            let target = NSHomeDirectory() + variant
            XCTAssertThrowsError(try validator.validate(target, allowedRoots: [])) { error in
                guard case AllowedRootsError.deniedHomePath = error else {
                    return XCTFail("expected deniedHomePath for case-variant '\(variant)', got \(error)")
                }
            }
        }
    }
}
