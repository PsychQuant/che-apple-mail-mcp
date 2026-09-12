import XCTest

final class RepositoryOwnerLinkTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testLiveReferencesUseTheCurrentRepositoryOwner() throws {
        for path in ["plugin/README.md", "mcpb/manifest.json", "PRIVACY.md", "mcpb/PRIVACY.md", "PROMOTION.md"] {
            let text = try read(path)
            XCTAssertFalse(text.contains("github.com/kiki830621/che-apple-mail-mcp"), path)
            XCTAssertTrue(text.contains("github.com/PsychQuant/che-apple-mail-mcp"), path)
        }
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(read("mcpb/manifest.json").utf8)) as? [String: Any])
        let author = try XCTUnwrap(manifest["author"] as? [String: Any])
        XCTAssertEqual(author["url"] as? String, "https://github.com/PsychQuant")
        XCTAssertEqual(author["name"] as? String, "Che Cheng")
        XCTAssertEqual(try read("PRIVACY.md"), try read("mcpb/PRIVACY.md"))
    }

    func testPersonalAttributionAndOtherRepositoriesArePreserved() throws {
        for path in ["README.md", "README_zh-TW.md"] {
            XCTAssertTrue(try read(path).contains("[@kiki830621](https://github.com/kiki830621)"), path)
        }
        for path in ["plugin/CLAUDE.md", "plugin/skills/confirmation-protocol/SKILL.md"] {
            XCTAssertTrue(try read(path).contains("kiki830621/foresay"), path)
        }
        for path in ["plugin/README.md", "plugin/commands/archive-mail.md"] {
            XCTAssertTrue(try read(path).contains("kiki830621/chchen-lab"), path)
        }
        XCTAssertTrue(try read("Tests/MailSQLiteTests/AccountMapperTests.swift").contains("kiki830621@gmail.com"))
    }
}
