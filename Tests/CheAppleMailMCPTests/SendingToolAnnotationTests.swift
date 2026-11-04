import XCTest
import MCP
@testable import CheAppleMailMCP

/// #601 — the four tools that can send mail declare it, so a client that
/// prompts on `destructiveHint` / `openWorldHint` asks before they run. Values
/// are the worst case of each tool: `reply_email` also has a draft mode, but
/// annotations are static and it can send.
final class SendingToolAnnotationTests: XCTestCase {

    private func tool(_ name: String) throws -> Tool {
        try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == name }, "missing tool \(name)")
    }

    func testSendingToolsDeclareTheyCanSend() throws {
        for name in ["compose_email", "reply_email", "forward_email", "redirect_email"] {
            let a = try tool(name).annotations
            XCTAssertEqual(a.readOnlyHint, false, name)
            XCTAssertEqual(a.destructiveHint, true, "\(name): a sent message cannot be recalled")
            XCTAssertEqual(a.idempotentHint, false, "\(name): a retry sends a second message (#242)")
            XCTAssertEqual(a.openWorldHint, true, "\(name): mail leaves for third parties")
            XCTAssertNil(a.title, name)
        }
    }

    func testTheSendingToolSetIsExactlyTheseFour() {
        XCTAssertEqual(CheAppleMailMCPServer.sendingToolNames,
                       ["compose_email", "reply_email", "forward_email", "redirect_email"])
    }

    func testOtherAnnotationsAreUnchanged() throws {
        let length = try tool("check_compose_length").annotations
        XCTAssertEqual(length, .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false))
        XCTAssertEqual(try tool("classify_emails").annotations.readOnlyHint, true)
        XCTAssertEqual(try tool("apply_email_classification").annotations.destructiveHint, true)
        // Tools outside the four and the classification / length tools stay unannotated (Diagnosis default).
        for name in ["create_draft", "update_draft", "list_accounts", "delete_email", "open_mailto"] {
            XCTAssertTrue(try tool(name).annotations.isEmpty, name)
        }
    }

    func testAnnotationsReachTheWire() throws {
        let data = try JSONEncoder().encode(try tool("compose_email"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let annotations = try XCTUnwrap(json["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, true)
        XCTAssertEqual(annotations["openWorldHint"] as? Bool, true)
    }
}
