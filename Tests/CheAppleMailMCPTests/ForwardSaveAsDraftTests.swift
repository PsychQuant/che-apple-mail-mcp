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

    /// Runs the `forward_email` tool through the MCP handler (`executeToolCall`), every script captured and
    /// answered "ok". `save_as_draft` is left out of the arguments when `flag` is nil, so "omitted" really is omitted.
    private func runForwardTool(body: String?, flag: Value?) async throws -> [String] {
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: { script in scripts.append(script); return "ok" },
                                                 refusal: { nil })
        var arguments: [String: Value] = [
            "id": .string("123"), "mailbox": .string("INBOX"), "account_name": .string("Work"),
            "to": .array([.string("me@example.invalid")]),
        ]
        if let body { arguments["body"] = .string(body) }
        if let flag { arguments["save_as_draft"] = flag }
        _ = try await makeToolServer().executeToolCall(name: "forward_email", arguments: arguments)
        return scripts
    }

    /// No send keystroke and no AppleScript `send` command anywhere in the script.
    private func assertSendsNothing(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(script.contains(send), "draft script must not press ⇧⌘D", file: file, line: line)
        XCTAssertNil(script.range(of: #"(?m)^\s*send\b"#, options: .regularExpression),
                     "draft script must not run an AppleScript send command", file: file, line: line)
    }

    // MARK: - spec-example: message-composition / forward_email save_as_draft

    /// Every row runs through the tool handler, so the wiring from `save_as_draft` to the controller is under test
    /// (#599 verify round 1, row 1: a handler that dropped the flag survived every controller-level test).
    func testExampleTable() async throws {
        // spec-example: message-composition / forward_email save_as_draft
        // "FYI" | true → paste path, save keystroke, no send keystroke, draft label
        let draft = try await runForwardTool(body: "FYI", flag: .bool(true))
        XCTAssertEqual(draft.count, 1)
        XCTAssertTrue(draft[0].contains(save))
        assertSendsNothing(draft[0])
        XCTAssertTrue(draft[0].contains("Forward saved as draft (paste path)"))
        XCTAssertTrue(draft[0].contains("forward"), "still Mail's native forward verb")

        // "FYI" | omitted, false, null → paste path, send keystroke (unchanged)
        for flag: Value? in [nil, .bool(false), .null] {
            let sent = try await runForwardTool(body: "FYI", flag: flag)
            XCTAssertEqual(sent.count, 1, "save_as_draft \(String(describing: flag))")
            XCTAssertTrue(sent[0].contains(send), "save_as_draft \(String(describing: flag)) must send")
            XCTAssertFalse(sent[0].contains(save))
            XCTAssertTrue(sent[0].contains("Email forwarded successfully (paste path)"))
        }

        // none | true → refused before any Mail operation, naming the reason, #673 and both alternatives
        var refusedScripts = 0
        await MailController.shared.setTestSeams(scriptRunner: { _ in refusedScripts += 1; return "" }, refusal: { nil })
        do {
            _ = try await makeToolServer().executeToolCall(name: "forward_email", arguments: [
                "id": .string("123"), "mailbox": .string("INBOX"), "account_name": .string("Work"),
                "to": .array([.string("me@example.invalid")]), "save_as_draft": .bool(true),
            ])
            XCTFail("a bare forward with save_as_draft must be refused")
        } catch MailError.invalidParameter(let message) {
            for needle in ["#673", "save_as_draft", "no step that could save", "Pass a body",
                           "forward the message in Mail by hand", "created and sent nothing"] {
                XCTAssertTrue(message.contains(needle), "refusal must contain '\(needle)': \(message)")
            }
        }
        XCTAssertEqual(refusedScripts, 0, "no Mail script may run for a refused bare-forward draft")

        // none | omitted → the native forward script, unchanged (ends in send)
        let bare = try await runForwardTool(body: nil, flag: nil)
        XCTAssertEqual(bare.count, 1)
        XCTAssertTrue(bare[0].contains("send fwdMsg"))

        // "FYI" | "yes" → refused: save_as_draft must be a boolean
        do {
            _ = try await runForwardTool(body: "FYI", flag: .string("yes"))
            XCTFail("a string save_as_draft must be refused")
        } catch MailError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("save_as_draft"), message)
        }
    }

    /// The builder alone: the draft variant differs from the send variant only in the dispatch step and label.
    func testBuilderDraftVariant() {
        let draft = buildForwardEmailPasteScript(messageRef: "msgRef", to: ["me@example.invalid"], newBody: "FYI", saveAsDraft: true)
        XCTAssertTrue(draft.contains(save))
        assertSendsNothing(draft)
        let sent = buildForwardEmailPasteScript(messageRef: "msgRef", to: ["me@example.invalid"], newBody: "FYI")
        XCTAssertTrue(sent.contains(send))
        XCTAssertEqual(sent, buildForwardEmailPasteScript(messageRef: "msgRef", to: ["me@example.invalid"], newBody: "FYI", saveAsDraft: false))
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
        for needle in ["save_as_draft", "#461", "#673", "not been run against Mail", "To recipients and body"] {
            XCTAssertTrue(d.contains(needle), "forward_email description must mention \(needle)")
        }
        XCTAssertLessThanOrEqual(d.count, 2048, "Claude Code truncates tool descriptions at 2,048 characters")
    }

    // MARK: - the refusal is a parameter refusal, not a row of the closed failure table

    private static func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The `message-composition` spec writes the bodyless refusal as a parameter refusal of `forward_email`, not
    /// as a reason the GUI path is ineligible, so the closed failure table of the rule keeps its nine classes. A
    /// tenth row would be a second classification of the same refusal.
    func testTheRuleCopiesKeepTheNineClassTableAndDescribeTheRefusalAsAParameterRefusal() throws {
        for path in [".claude/rules/compose-wrapper-free.md", "plugin/rules/compose-wrapper-free.md"] {
            let rule = try Self.repoFile(path)
            XCTAssertTrue(rule.contains("封閉九類，不得依性質相似類推第十類"), "\(path): the heading keeps nine classes")
            XCTAssertFalse(rule.contains("封閉十類"), "\(path): no ten-class heading")
            XCTAssertFalse(rule.contains("第十一類"), "\(path): no eleventh class")
            XCTAssertFalse(rule.contains("十類與各自的處置"), "\(path): the sentence before the table says nine")
            XCTAssertTrue(rule.contains("九類與各自的處置"), "\(path): the sentence before the table says nine")
            XCTAssertNil(rule.range(of: "\n| 10 |"), "\(path): the table has no row 10")
            XCTAssertNil(rule.range(of: "第 10 類"), "\(path): nothing calls the refusal class 10")
            XCTAssertTrue(rule.contains("| 9 |"), "\(path): the ninth row stays")
            // The refusal stays documented: a parameter refusal at the tool's entry, before any Mail action,
            // with the follow-up that removes it.
            for needle in ["save_as_draft", "參數拒絕", "#673", "任何 Mail 動作之前"] {
                XCTAssertTrue(rule.contains(needle), "\(path): the refusal paragraph must mention \(needle)")
            }
        }
        let other = try Self.repoFile(".claude/rules/timeout-outcome-boundary.md")
        XCTAssertTrue(other.contains("封閉的九類事前拒絕"), "the timeout rule counts nine classes")
        XCTAssertFalse(other.contains("十類"), "the timeout rule does not count ten")
    }

    func testTheReadmeLinksTheNineClassHeadingAndNamesNoTenthReason() throws {
        let readme = try Self.repoFile("README.md")
        XCTAssertTrue(readme.contains("#呼叫失敗時怎麼辦封閉九類不得依性質相似類推第十類"), "README anchors the nine-class heading")
        XCTAssertFalse(readme.contains("封閉十類"), "README has no ten-class anchor")
        XCTAssertFalse(readme.contains("current ten reasons"), "README counts nine reasons")
        XCTAssertFalse(readme.contains("the tenth"), "README names no tenth reason")
    }
}
