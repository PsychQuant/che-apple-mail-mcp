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

    func testAnUnexpandedPlaceholderIsIgnoredAndNoted() {
        var logs: [String] = []
        let roots = AllowedRootsValidator.configuredRoots(
            from: "${user_config.export_allowed_roots}", log: { logs.append($0) })
        XCTAssertEqual(roots, [])
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("#574"))

        XCTAssertEqual(AllowedRootsValidator.configuredRoots(from: "/a:${x}", log: { _ in }), ["/a"])
        // Not a placeholder: a real directory name may contain `$` or braces.
        XCTAssertEqual(AllowedRootsValidator.configuredRoots(from: "/a/${x", log: { _ in }), ["/a/${x"])
    }

    func testAPlaceholderKeepsTheHomeDefault() throws {
        let roots = AllowedRootsValidator.configuredRoots(from: "${user_config.export_allowed_roots}", log: { _ in })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let target = home + "/che-mail-574-probe-\(UUID().uuidString)/out"
        // Validation only canonicalizes; nothing is created.
        XCTAssertNoThrow(try AllowedRootsValidator().validate(target, allowedRoots: roots))
        XCTAssertThrowsError(try AllowedRootsValidator().validate(target, allowedRoots: ["${user_config.export_allowed_roots}"]),
                             "without the guard the literal placeholder would replace home and deny it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (target as NSString).deletingLastPathComponent))
    }
}
