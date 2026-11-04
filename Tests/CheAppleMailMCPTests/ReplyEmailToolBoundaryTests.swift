import XCTest
import MCP
@testable import CheAppleMailMCP

/// #534 — `reply_email` driven through the MCP handler (`executeToolCall`), not
/// through `MailController` directly. The handler is the only hop that carries
/// `attachments` to `replyEmail`, and it parses `format` before anything else,
/// so the reason a call reports is decided here as much as in
/// `replyForwardRefusal`.
final class ReplyEmailToolBoundaryTests: XCTestCase {

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    /// The handler is the only hop that carries `attachments` from the MCP call
    /// to `replyEmail`. Dropping it there would make every attachment silently
    /// vanish while the reply is saved or sent — the same false success #534
    /// removes. Driven through `executeToolCall` with the real derivation.
    func testReplyEmailTool_withAttachments_refusedByName_noScript() async throws {
        var calls = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in calls += 1; return "Reply saved as draft (paste path)" },
            refusal: nil)
        let server = try await makeToolServer()
        for saveAsDraft in [true, false] {
            do {
                _ = try await server.executeToolCall(name: "reply_email", arguments: replyArguments(
                    extra: ["attachments": .array([.string("/tmp/che-mail-534.pdf")]),
                            "save_as_draft": .bool(saveAsDraft)]))
                XCTFail("reply_email with attachments must be refused (save_as_draft=\(saveAsDraft))")
            } catch MailError.invalidParameter(let message) {
                XCTAssertTrue(message.contains("#608"), message)
            } catch {
                XCTFail("expected a named invalidParameter refusal, got \(error)")
            }
        }
        XCTAssertEqual(calls, 0, "no script may run — nothing saved, nothing sent")
    }

    /// The tool parses `format` before it calls into Mail, so markdown with
    /// attachments reports reason 1 (Requirement: Composing tools accept a
    /// format parameter), not reason 9. This pins the order the spec states.
    func testReplyEmailTool_markdownWithAttachments_reportsFormatFirst() async throws {
        var calls = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in calls += 1; return "" },
            refusal: nil)
        let server = try await makeToolServer()
        do {
            _ = try await server.executeToolCall(name: "reply_email", arguments: replyArguments(
                extra: ["attachments": .array([.string("/tmp/che-mail-534.pdf")]),
                        "format": .string("markdown")]))
            XCTFail("markdown must be refused")
        } catch MailError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("no longer supported"), message)
            XCTAssertFalse(message.contains("#608"), "format is parsed first: \(message)")
        } catch {
            XCTFail("expected the named format refusal, got \(error)")
        }
        XCTAssertEqual(calls, 0, "no script may run")
    }

    private func makeToolServer() async throws -> CheAppleMailMCPServer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try await CheAppleMailMCPServer(
            databasePath: root.appendingPathComponent("missing.sqlite").path,
            initialSync: false, classificationDirectory: root)
    }

    /// `account_name` has no "@", so the handler resolves no account id and
    /// reads no AccountsMap entry.
    private func replyArguments(extra: [String: Value]) -> [String: Value] {
        var arguments: [String: Value] = [
            "id": .string("1"), "mailbox": .string("INBOX"),
            "account_name": .string("Che534Test"), "body": .string("b"),
        ]
        arguments.merge(extra) { _, new in new }
        return arguments
    }
}
