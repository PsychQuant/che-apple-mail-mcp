import XCTest
import MCP
@testable import CheAppleMailMCP

/// #574 — the `.mcpb` install had no way to set CHE_MAIL_EXPORT_ALLOWED_ROOTS.
/// The manifest now maps an optional `user_config` string onto it, and the
/// server ignores an unexpanded `${...}` placeholder so an unset setting that a
/// host passes through literally cannot replace the home allowance with a root
/// that does not exist.
final class ExportAllowedRootsConfigTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("mcpb/manifest.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - manifest

    func testManifestMapsTheUserSettingOntoTheVariable() throws {
        let m = try manifest()
        let env = try XCTUnwrap(((m["server"] as? [String: Any])?["mcp_config"] as? [String: Any])?["env"] as? [String: String])
        XCTAssertEqual(env["CHE_MAIL_EXPORT_ALLOWED_ROOTS"], "${user_config.export_allowed_roots}")
        XCTAssertEqual(env.count, 1, "no other variable is set by the bundle")
    }

    func testTheSettingIsAnOptionalStringWithAnEmptyDefault() throws {
        let config = try XCTUnwrap(try manifest()["user_config"] as? [String: Any])
        // Every `${user_config.KEY}` the env uses must exist, and only this one.
        XCTAssertEqual(Set(config.keys), ["export_allowed_roots"])
        let entry = try XCTUnwrap(config["export_allowed_roots"] as? [String: Any])
        // A string, not `directory` + `multiple`: the spec defines array
        // expansion only for `args`, and the server needs one `:`-joined value.
        XCTAssertEqual(entry["type"] as? String, "string")
        XCTAssertEqual(entry["required"] as? Bool, false)
        XCTAssertEqual(entry["default"] as? String, "", "unset must mean the home default")
        let description = try XCTUnwrap(entry["description"] as? String)
        XCTAssertTrue(description.contains("REPLACE"), "the replace-home semantics must be stated")
        XCTAssertNotNil(entry["title"] as? String)
    }

    // MARK: - KNOWN GATE (deferred-live-verification.md)

    /// How Claude Desktop passes an empty optional setting was not observed on a
    /// real install, so the caveat lives where a caller can read it.
    func testToolDescriptionsCarryTheLiveCaveat() throws {
        let tools = CheAppleMailMCPServer.defineTools()
        let save = try XCTUnwrap(tools.first { $0.name == "save_attachment" })
        XCTAssertTrue((save.description ?? "").contains("not checked on a real install (#574)"))
        let export = try XCTUnwrap(tools.first { $0.name == "batch_export_emails_markdown" })
        let schema = try XCTUnwrap(String(data: JSONEncoder().encode(export.inputSchema), encoding: .utf8))
        XCTAssertTrue(schema.contains("not checked on a real install (#574)"), "output_dir")
    }

    // MARK: - parsing

    func testParsing() {
        var logs: [String] = []
        let parse = { AllowedRootsValidator.configuredRoots(from: $0, log: { logs.append($0) }) }
        XCTAssertEqual(parse(nil), [])
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("/Volumes/Archive"), ["/Volumes/Archive"])
        XCTAssertEqual(parse("/a::/b"), ["/a", "/b"])
        XCTAssertEqual(logs, [])
    }

    /// The home directory; no test here writes under it.
    private var homeTarget: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/che-mail-574-probe-\(UUID().uuidString)/out"
    }

    private func parse(_ raw: String?) -> [String] {
        AllowedRootsValidator.configuredRoots(from: raw, log: { _ in })
    }

    func testOnlyTheWholeValueBeingTheManifestPlaceholderMeansUnset() throws {
        var logs: [String] = []
        let raw = "${user_config.export_allowed_roots}"
        let roots = AllowedRootsValidator.configuredRoots(from: raw, log: { logs.append($0) })
        XCTAssertEqual(roots, [], "a host that passes the unset setting through literally keeps the default")
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("#574"))
        // Validation only canonicalizes; nothing is created.
        XCTAssertNoThrow(try AllowedRootsValidator().validate(homeTarget, allowedRoots: roots))
    }

    /// Every one of these is a nonempty value that names no usable root. A
    /// nonempty value is a restriction someone asked for, so it must not fall
    /// back to all of home (#574 review: the first version filtered every
    /// `${...}` entry, emptied the list, and silently widened it to home).
    func testAnyOtherUnusableValueDeniesInsteadOfFallingBackToHome() throws {
        let values = ["${OTHER}", "${user_config.other}", "${}", "${user_config.export_allowed_roots}:${OTHER}",
                      " ${user_config.export_allowed_roots}", "undefined", "null", " ", "Mail", ":", "::"]
        for raw in values {
            let roots = parse(raw)
            XCTAssertFalse(roots.isEmpty, "\(raw.debugDescription) must not read as unset")
            XCTAssertThrowsError(try AllowedRootsValidator().validate(homeTarget, allowedRoots: roots),
                                 "\(raw.debugDescription) fell back to home")
        }
    }

    func testAPlaceholderBesideARealRootDoesNotBecomeUnset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("che-mail-574-\(UUID().uuidString)").path
        for raw in ["\(dir):${user_config.export_allowed_roots}", "\(dir):${OTHER}"] {
            let roots = parse(raw)
            XCTAssertNoThrow(try AllowedRootsValidator().validate(dir + "/out", allowedRoots: roots), raw)
            XCTAssertThrowsError(try AllowedRootsValidator().validate(homeTarget, allowedRoots: roots), raw)
        }
    }

    /// `canonicalize` runs a relative path through `URL(fileURLWithPath:)`, which
    /// resolves it against the process's working directory, so a relative entry
    /// left as written would authorize whatever sits under the server's cwd.
    func testARelativeEntryIsNotResolvedAgainstTheWorkingDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("che-mail-574-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("exports"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("${OTHER}"), withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let previous = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(dir.path))
        defer { fm.changeCurrentDirectoryPath(previous) }

        for (raw, target) in [("exports", "exports/out"), ("${OTHER}", "${OTHER}/out")] {
            let inCwd = dir.appendingPathComponent(target).path
            XCTAssertThrowsError(try AllowedRootsValidator().validate(inCwd, allowedRoots: parse(raw)), raw)
        }
        XCTAssertThrowsError(
            try AttachmentDestination(savePath: dir.appendingPathComponent("exports/file.txt").path,
                                      allowedRoots: parse("exports"))) { error in
            guard case AttachmentDestinationError.rejected = error else { return XCTFail("\(error)") }
        }
    }

    func testAnUnusableEntryIsNoted() {
        var logs: [String] = []
        _ = AllowedRootsValidator.configuredRoots(from: "${OTHER}", log: { logs.append($0) })
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("not an absolute path"), logs.first ?? "")
    }

    func testATildeRootStaysUsable() throws {
        let roots = parse("~/che-mail-574-root")
        XCTAssertEqual(roots, ["~/che-mail-574-root"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertNoThrow(try AllowedRootsValidator().validate(home + "/che-mail-574-root/out", allowedRoots: roots))
    }

    func testAPathContainingDollarBracesIsStillARoot() {
        XCTAssertEqual(parse("/a/${x"), ["/a/${x"])
        XCTAssertEqual(parse("/a/${x}"), ["/a/${x}"], "an absolute path is a root whatever it contains")
    }
}
