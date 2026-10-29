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

    // MARK: - #402 verify: cloud-sync folders, full case folding, agent config

    private let fixtureHome = "/Users/fixture"
    /// Provider folders that exist in the fixture home's CloudStorage.
    private let providers: Set<String> = ["/Users/fixture/Library/CloudStorage/Dropbox",
                                          "/Users/fixture/Library/CloudStorage/GoogleDrive-x",
                                          "/Users/fixture/Library/Mobile Documents/iCloud~md~obsidian/Documents"]

    private func policy(_ path: String, roots: [String] = []) throws {
        try validator.validateCanonicalPath(path, homePath: fixtureHome, allowedRoots: roots,
                                            deniedTargets: [], directoryExists: providers.contains)
    }

    /// `~/Dropbox` (and Google Drive, OneDrive, Box) resolve into
    /// `~/Library/CloudStorage`, and iCloud Drive is `~/Library/Mobile
    /// Documents/com~apple~CloudDocs`. Denying them with the rest of
    /// `~/Library` rejected every cloud-synced archive folder, with no root
    /// able to allow it.
    func testCloudStorageInsideLibraryIsPermitted() throws {
        for path in ["/Library/CloudStorage/Dropbox/ws/a.pdf",
                     "/Library/CloudStorage/GoogleDrive-x/My Drive/a.pdf",
                     "/Library/Mobile Documents/com~apple~CloudDocs/a.pdf",
                     "/library/mobile documents/COM~APPLE~CLOUDDOCS/a.pdf",
                     "/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/a.md",
                     "/Library/CloudStorage/Dropbox"] {
            XCTAssertNoThrow(try policy(fixtureHome + path), path)
        }
        let root = fixtureHome + "/Library/CloudStorage/Dropbox/ws"
        XCTAssertNoThrow(try policy(root + "/a.pdf", roots: [root]))
        XCTAssertThrowsError(try policy(fixtureHome + "/Documents/a.pdf", roots: [root]),
                             "configured roots still replace home")
    }

    /// The other children of Mobile Documents are apps' iCloud containers — Mail
    /// keeps its synced signatures there — and anything directly under
    /// CloudStorage that is not an existing provider folder stays denied.
    func testTheRestOfLibraryStaysDenied() {
        for path in ["/Library/LaunchAgents/x.plist", "/Library/CloudStorage",
                     "/Library/Mobile Documents",
                     "/Library/Mobile Documents/com~apple~mail/Data/V4/Signatures/x.mailsignature",
                     "/Library/Mobile Documents/iCloud~md~obsidian/x.md",
                     "/Library/CloudStorage/x.pdf", "/Library/CloudStorage/NewFolder/x.pdf",
                     "/Library/Mobile Documents/iCloud~new~app/Documents/x.md",
                     "/Library/CloudStorageX/a", "/Library/Preferences/CloudStorage/a", "/Library"] {
            XCTAssertThrowsError(try policy(fixtureHome + path), path) { error in
                guard case AllowedRootsError.deniedHomePath = error else { return XCTFail("\(path): \(error)") }
            }
        }
    }

    /// A dotfile kept in a cloud folder resolves into a permitted folder; the
    /// resolved targets of the denied names keep it denied, and the caller's own
    /// spelling is checked too.
    func testADeniedNameLinkedIntoACloudFolderStaysDenied() throws {
        let fm = FileManager.default
        let home = try XCTUnwrap(realpath(fm.temporaryDirectory.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) })
            + "/idd402-home-\(UUID().uuidString)"
        addTeardownBlock { try? fm.removeItem(atPath: home) }
        let dotfiles = home + "/Library/CloudStorage/Dropbox/dotfiles"
        try fm.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dotfiles + "/.zshrc"))
        try fm.createSymbolicLink(atPath: home + "/.zshrc", withDestinationPath: dotfiles + "/.zshrc")
        try fm.createDirectory(atPath: dotfiles + "/ssh", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.ssh", withDestinationPath: dotfiles + "/ssh")

        for target in [dotfiles + "/.zshrc", dotfiles + "/ssh/authorized_keys"] {
            XCTAssertThrowsError(try validator.validateCanonicalPath(target, homePath: home, allowedRoots: []), target)
        }
        XCTAssertNoThrow(try validator.validateCanonicalPath(dotfiles + "/notes.md", homePath: home, allowedRoots: []))
        XCTAssertThrowsError(try validator.checkHomeNames(home + "/.zshrc", homePath: home),
                             "the caller's spelling of a denied name is denied before resolution")
    }

    /// The other link shapes: a denied name pointing at a file that does not
    /// exist yet (writing the target would make the link live), a chain of
    /// links, and a link directly inside a denied directory (`~/.claude/hooks`
    /// kept in a config repository).
    func testDanglingChainedAndNestedLinksOfDeniedNamesStayDenied() throws {
        let fm = FileManager.default
        let home = try XCTUnwrap(realpath(fm.temporaryDirectory.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) })
            + "/idd402-home-\(UUID().uuidString)"
        addTeardownBlock { try? fm.removeItem(atPath: home) }
        let cloud = home + "/Library/CloudStorage/Dropbox/dotfiles"
        let repo = home + "/Developer/config"
        try fm.createDirectory(atPath: cloud, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: repo + "/hooks", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.zshrc", withDestinationPath: cloud + "/shellrc")      // dangling
        try fm.createSymbolicLink(atPath: home + "/.zshenv", withDestinationPath: home + "/env-link")    // chain
        try fm.createSymbolicLink(atPath: home + "/env-link", withDestinationPath: cloud + "/env")       // dangling end
        try fm.createSymbolicLink(atPath: home + "/.claude/hooks", withDestinationPath: repo + "/hooks") // nested

        for target in [cloud + "/shellrc", cloud + "/env", repo + "/hooks/session-start.sh"] {
            XCTAssertThrowsError(try validator.validateCanonicalPath(target, homePath: home, allowedRoots: []), target)
        }
        for allowed in [cloud + "/notes.md", repo + "/README.md"] {
            XCTAssertNoThrow(try validator.validateCanonicalPath(allowed, homePath: home, allowedRoots: []), allowed)
        }
    }

    /// Two more shapes: a dangling directory link partway along a denied name's
    /// target, and a denied folder that is itself a link (stow's tree folding),
    /// whose children are links too.
    func testIntermediateDanglingLinksAndLinkedDeniedFoldersStayDenied() throws {
        let fm = FileManager.default
        let home = try XCTUnwrap(realpath(fm.temporaryDirectory.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) })
            + "/idd402-home-\(UUID().uuidString)"
        addTeardownBlock { try? fm.removeItem(atPath: home) }
        let config = home + "/Developer/config"
        try fm.createDirectory(atPath: config, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: config + "/alias", withDestinationPath: config + "/not-yet-created")
        try fm.createSymbolicLink(atPath: home + "/.zshrc", withDestinationPath: config + "/alias/rc")
        let dotfiles = home + "/Developer/dotfiles/config"
        try fm.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/Developer/nvim-config", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.config", withDestinationPath: dotfiles)
        try fm.createSymbolicLink(atPath: dotfiles + "/nvim", withDestinationPath: home + "/Developer/nvim-config")

        for target in [config + "/not-yet-created/rc", home + "/Developer/nvim-config/init.lua", dotfiles + "/x"] {
            XCTAssertThrowsError(try validator.validateCanonicalPath(target, homePath: home, allowedRoots: []), target)
        }
        XCTAssertNoThrow(try validator.validateCanonicalPath(config + "/README.md", homePath: home, allowedRoots: []))
    }

    /// The caller's spelling is compared with the home prefix folded, as the
    /// default volume compares it.
    func testTheHomePrefixIsComparedCaseInsensitively() {
        XCTAssertThrowsError(try validator.checkHomeNames("/users/FIXTURE/.ssh/x", homePath: fixtureHome))
    }

    /// APFS folds `ſ` to `s` and `ﬆ` to `st`; `lowercased()` does neither, so
    /// `~/.ſſh` passed the denylist while opening `~/.ssh`.
    func testCaseFoldingVariantsOfDeniedNamesAreDenied() {
        for path in ["/.ſſh/authorized_keys", "/.SSH/x", "/.kube/config", "/LIBRARY/LaunchAgents/x"] {
            XCTAssertThrowsError(try policy(fixtureHome + path), path)
        }
    }

    func testShellStartupAndAgentConfigAreDenied() {
        for name in [".zshenv", ".zlogin", ".zlogout", ".bash_login", ".bash_logout",
                     ".claude/settings.json", ".claude.json", ".mcp.json", ".codex/config.toml", ".cursor/mcp.json"] {
            XCTAssertThrowsError(try policy(fixtureHome + "/" + name), name)
        }
    }

    /// `canonicalPath.hasPrefix("/" + "/")` never matched, so a root of "/"
    /// rejected everything. It now permits everything outside the system and
    /// home denylists.
    func testRootOfSlashPermitsEverythingOutsideTheDenylists() throws {
        XCTAssertNoThrow(try policy("/Volumes/Archive/a.pdf", roots: ["/"]))
        XCTAssertThrowsError(try policy("/etc/hosts", roots: ["/"]))
        XCTAssertThrowsError(try policy(fixtureHome + "/.ssh/x", roots: ["/"]))
    }
}
