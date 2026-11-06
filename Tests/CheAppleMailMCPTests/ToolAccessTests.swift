import XCTest
import MCP
@testable import CheAppleMailMCP

/// #601, #621 — every tool says what it does, so a client can tell a read from
/// a delete. A spec-conforming client reads a tool without annotations as
/// possibly destructive and open world, which is why the table is closed.
final class ToolAccessTests: XCTestCase {

    /// The tools that annotate themselves where they are defined.
    private static let selfAnnotated = [
        "apply_email_classification", "check_compose_length", "classify_emails",
        "configure_email_classification", "get_email_classification_policy",
    ]

    private static func hints(_ a: Tool.Annotations) -> [Bool?] {
        [a.readOnlyHint, a.destructiveHint, a.idempotentHint, a.openWorldHint]
    }

    private func tool(_ name: String) throws -> Tool {
        try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == name }, "missing tool \(name)")
    }

    // MARK: - The table is closed

    func testEveryToolIsClassified() {
        let unclassified = CheAppleMailMCPServer.defineTools().map(\.name).filter { ToolAccess.of($0) == nil }.sorted()
        XCTAssertEqual(unclassified, Self.selfAnnotated,
                       "a new tool needs a class in ToolAccess (or annotations of its own, listed here)")
    }

    func testNoToolIsInTwoClassesAndNoEntryIsStale() {
        let listed = ToolAccess.allCases.flatMap(\.toolNames)
        XCTAssertEqual(listed.count, Set(listed).count, "a tool is listed twice")
        XCTAssertEqual(Set(listed).subtracting(CheAppleMailMCPServer.defineTools().map(\.name)), [],
                       "the table names a tool that does not exist")
    }

    func testEveryToolCarriesItsClassesAnnotations() {
        for tool in CheAppleMailMCPServer.defineTools() {
            XCTAssertFalse(tool.annotations.isEmpty, tool.name)
            if let access = ToolAccess.of(tool.name) {
                XCTAssertEqual(tool.annotations, access.annotations, tool.name)
            }
        }
    }

    // MARK: - What each class states

    func testClassValues() {
        func hints(_ access: ToolAccess) -> [Bool?] { Self.hints(access.annotations) }
        XCTAssertEqual(hints(.readLocal), [true, false, true, false])
        XCTAssertEqual(hints(.readMail), [true, false, true, true], "the text comes from third parties")
        XCTAssertEqual(hints(.add), [false, false, false, false], "a repeat adds another")
        XCTAssertEqual(hints(.fetch), [false, false, true, true])
        XCTAssertEqual(hints(.prepareMail), [false, false, false, true])
        XCTAssertEqual(hints(.change), [false, true, false, false])
        XCTAssertEqual(hints(.replaceDraft), [false, true, false, true])
        XCTAssertEqual(hints(.writeFile), [false, true, false, false], "a repeated export adds copies")
        XCTAssertEqual(hints(.send), [false, true, false, true])
    }

    func testToolsThatMustNotReadAsSafe() throws {
        for name in ["delete_email", "delete_mailbox", "delete_rule", "move_email", "update_draft", "mark_as_junk",
                     "import_mailbox"] {
            let a = try tool(name).annotations
            XCTAssertEqual(a.readOnlyHint, false, name)
            XCTAssertEqual(a.destructiveHint, true, name)
        }
    }

    func testToolsThatReturnMailAreOpenWorld() throws {
        for name in ["get_email", "get_email_source", "get_emails_batch", "search_emails", "list_emails",
                     "list_vip_senders"] {
            XCTAssertEqual(try tool(name).annotations.openWorldHint, true, name)
        }
    }

    /// The tools where "may a client run this unasked" was the real question.
    func testTheCallsThatWereWeighed() throws {
        for name in ["create_draft", "open_mailto"] {
            XCTAssertEqual(Self.hints(try tool(name).annotations), [false, false, false, true],
                           "\(name) removes nothing, but its text leaves Mail's local store")
        }
        XCTAssertEqual(Self.hints(try tool("update_draft").annotations), [false, true, false, true],
                       "the old draft is deleted, and the new one syncs")
        XCTAssertEqual(Self.hints(try tool("copy_email").annotations), [false, false, false, false])
        XCTAssertEqual(Self.hints(try tool("import_mailbox").annotations), [false, true, false, false],
                       "an import is not undone in one step")
        for name in ["export_emails_markdown", "batch_export_emails_markdown"] {
            XCTAssertEqual(Self.hints(try tool(name).annotations), [false, true, false, false],
                           "\(name): a repeat adds -N copies, and an attachment of the same name is replaced")
        }
    }

    // MARK: - #601, the tools that can send

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
        XCTAssertEqual(ToolAccess.send.toolNames, ["compose_email", "reply_email", "forward_email", "redirect_email"])
    }

    func testAnnotationsDefinedWithTheToolAreKept() throws {
        let length = try tool("check_compose_length").annotations
        XCTAssertEqual(length, .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false))
        XCTAssertEqual(try tool("classify_emails").annotations.readOnlyHint, true)
        XCTAssertEqual(try tool("apply_email_classification").annotations.destructiveHint, true)
        XCTAssertEqual(Self.hints(try tool("get_email_classification_policy").annotations), [true, false, true, false])
        XCTAssertEqual(Self.hints(try tool("configure_email_classification").annotations), [false, true, false, false])
    }

    func testAnnotationsReachTheWire() throws {
        let data = try JSONEncoder().encode(try tool("compose_email"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let annotations = try XCTUnwrap(json["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, true)
        XCTAssertEqual(annotations["openWorldHint"] as? Bool, true)

        let readData = try JSONEncoder().encode(try tool("list_accounts"))
        let readJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: readData) as? [String: Any])
        let readAnnotations = try XCTUnwrap(readJSON["annotations"] as? [String: Any])
        XCTAssertEqual(readAnnotations["readOnlyHint"] as? Bool, true)
    }
}
