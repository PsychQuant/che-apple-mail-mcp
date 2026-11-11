import XCTest
import MCP
@testable import CheAppleMailMCP

/// #599 — `forward_email` gains `save_as_draft`. With a body, the same paste path saves the forward with ⌘S
/// instead of sending it. Without a body the call is refused by name for now (#673): the bodyless forward is
/// Mail's native `forward` verb followed by `send`, with no keystroke step that could save it.
///
/// No live Mail action here: every Mail script goes through the test seam.
final class ForwardSaveAsDraftTests: XCTestCase {

    private let send = "keystroke \"d\" using {command down, shift down}"
    private let save = "keystroke \"s\" using command down"

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    /// No Envelope Index and no account lookup: `account_name` has no "@" in the handler call below.
    private func makeToolServer() async throws -> CheAppleMailMCPServer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try await CheAppleMailMCPServer(
            databasePath: root.appendingPathComponent("missing.sqlite").path,
            initialSync: false, classificationDirectory: root)
    }

    /// Runs `forwardEmail` with every script captured and answered with `reply`.
    private func runForward(body: String?, saveAsDraft: Bool, reply: String = "ok") async throws -> (result: String, scripts: [String]) {
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: { script in scripts.append(script); return reply },
                                                 refusal: { nil })
        let result = try await MailController.shared.forwardEmail(
            id: "123", mailbox: "INBOX", accountName: "me@example.invalid",
            to: ["me@example.invalid"], body: body, saveAsDraft: saveAsDraft)
        return (result, scripts)
    }

    // MARK: - spec-example: message-composition / forward_email save_as_draft

    func testExampleTable() async throws {
        // spec-example: message-composition / forward_email save_as_draft
        // body + save_as_draft: true → paste path, save keystroke, no send keystroke, draft label
        let draft = buildForwardEmailPasteScript(messageRef: "msgRef", to: ["me@example.invalid"], newBody: "FYI", saveAsDraft: true)
        XCTAssertTrue(draft.contains(save))
        XCTAssertFalse(draft.contains(send))
        XCTAssertTrue(draft.contains("Forward saved as draft (paste path)"))
        XCTAssertTrue(draft.contains("forward"), "still Mail's native forward verb")

        // body, save_as_draft omitted or false → unchanged send script
        let sent = buildForwardEmailPasteScript(messageRef: "msgRef", to: ["me@example.invalid"], newBody: "FYI")
        XCTAssertTrue(sent.contains(send))
        XCTAssertFalse(sent.contains(save))
        XCTAssertTrue(sent.contains("Email forwarded successfully (paste path)"))
        XCTAssertEqual(sent, buildForwardEmailPasteScript(messageRef: "msgRef", to: ["me@example.invalid"], newBody: "FYI", saveAsDraft: false))

        // through the controller: the draft flow runs exactly the draft script
        let viaController = try await runForward(body: "FYI", saveAsDraft: true)
        XCTAssertEqual(viaController.scripts.count, 1)
        XCTAssertTrue(viaController.scripts[0].contains(save))
        XCTAssertFalse(viaController.scripts[0].contains(send))

        // no body + save_as_draft: true → refused before any Mail script
        await MailController.shared.setTestSeams(scriptRunner: { script in
            XCTFail("no Mail script may run for a refused bare-forward draft; got \(script.prefix(60))")
            return ""
        }, refusal: { nil })
        do {
            _ = try await MailController.shared.forwardEmail(
                id: "123", mailbox: "INBOX", accountName: "me@example.invalid",
                to: ["me@example.invalid"], body: nil, saveAsDraft: true)
            XCTFail("a bare forward with save_as_draft must be refused")
        } catch MailError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("#673"), message)
            XCTAssertTrue(message.contains("save_as_draft"), message)
        }

        // no body, save_as_draft omitted → the native forward script, unchanged (ends in send)
        let bare = try await runForward(body: nil, saveAsDraft: false)
        XCTAssertEqual(bare.scripts.count, 1)
        XCTAssertTrue(bare.scripts[0].contains("send fwdMsg"))

        // a non-boolean save_as_draft is refused by the handler
        let server = try await makeToolServer()
        do {
            _ = try await server.executeToolCall(name: "forward_email", arguments: [
                "id": .string("123"), "mailbox": .string("INBOX"), "account_name": .string("Work"),
                "to": .array([.string("me@example.invalid")]), "body": .string("FYI"), "save_as_draft": .string("yes"),
            ])
            XCTFail("a string save_as_draft must be refused")
        } catch MailError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("save_as_draft"), message)
        }
    }

    // MARK: - scenarios

    /// Scenario: a draft-flow timeout is not an unknown send state; a sending forward's still is.
    func testADraftTimeoutIsNotAnUnknownSendState_butASendTimeoutStillIs() async throws {
        let timeout = MailError.scriptTimedOut(seconds: 90, automationGranted: true, execution: .subprocess(exitConfirmed: true))
        await MailController.shared.setTestSeams(scriptRunner: { _ in throw timeout }, refusal: { nil })
        do {
            _ = try await MailController.shared.forwardEmail(
                id: "123", mailbox: "INBOX", accountName: "me@example.invalid",
                to: ["me@example.invalid"], body: "FYI", saveAsDraft: true)
            XCTFail("must throw")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("UNKNOWN"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(timeoutVerificationHint(.draftSave)), error.localizedDescription)
        }
        do {
            _ = try await MailController.shared.forwardEmail(
                id: "123", mailbox: "INBOX", accountName: "me@example.invalid",
                to: ["me@example.invalid"], body: "FYI", saveAsDraft: false)
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("UNKNOWN"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("NOT retrying"), error.localizedDescription)
        }
    }

    // MARK: - schema and description

    func testSchemaAndDescription() throws {
        let tool = try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == "forward_email" })
        guard case .object(let schema) = tool.inputSchema, case .object(let props)? = schema["properties"],
              case .object(let flag)? = props["save_as_draft"], case .string(let type)? = flag["type"] else {
            return XCTFail("forward_email must have a boolean save_as_draft property")
        }
        XCTAssertEqual(type, "boolean")
        let d = tool.description ?? ""
        let first = d.components(separatedBy: ". ").first ?? ""
        XCTAssertTrue(first.contains("SENDS"), "the first sentence must say the call sends: \(first)")
        for needle in ["save_as_draft", "#461", "#673", "not been run against Mail"] {
            XCTAssertTrue(d.contains(needle), "forward_email description must mention \(needle)")
        }
        XCTAssertLessThanOrEqual(d.count, 2048, "Claude Code truncates tool descriptions at 2,048 characters")
    }
}
