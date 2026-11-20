import XCTest
import MCP
@testable import CheAppleMailMCP

/// #674 — `forward_email` read its optional `body` leniently, so a body that was
/// present but not a string was treated as no body: without `save_as_draft` the
/// forward went out bare, without the note the caller supplied.
///
/// No live Mail action here: every Mail script goes through the test seam.
final class ForwardBodyTypeTests: XCTestCase {

    private let sendKeystroke = "keystroke \"d\" using {command down, shift down}"
    private let pasteKeystroke = "keystroke \"v\" using command down"

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    /// No Envelope Index. With the default `account_name` ("Work", no "@") there is
    /// no account lookup either; `accountMapping` is only for the precedence test.
    private func makeToolServer(accountMapping: [String: String]? = nil) async throws -> CheAppleMailMCPServer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try await CheAppleMailMCPServer(
            databasePath: root.appendingPathComponent("missing.sqlite").path,
            initialSync: false, classificationDirectory: root, accountMapping: accountMapping)
    }

    /// What one call did: the Mail scripts it handed to the seam, and the error
    /// it threw, if any. Both belong to this call only.
    private struct Outcome {
        var scripts: [String]
        var error: Error?

        /// The invalid-parameter message, or nil when the call did not fail that way.
        var invalidParameter: String? {
            if case MailError.invalidParameter(let message)? = error { return message }
            return nil
        }
    }

    /// Runs the tool through the MCP handler. `body` and `flag` are left out of
    /// the arguments when nil, so "missing" really is missing.
    private func run(body: Value?, flag: Value? = nil, accountName: String = "Work",
                     accountMapping: [String: String]? = nil) async throws -> Outcome {
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: { script in scripts.append(script); return "ok" },
                                                 refusal: { nil })
        var arguments: [String: Value] = [
            "id": .string("123"), "mailbox": .string("INBOX"), "account_name": .string(accountName),
            "to": .array([.string("me@example.invalid")]),
        ]
        if let body { arguments["body"] = body }
        if let flag { arguments["save_as_draft"] = flag }
        let server = try await makeToolServer(accountMapping: accountMapping)
        do {
            _ = try await server.executeToolCall(name: "forward_email", arguments: arguments)
            return Outcome(scripts: scripts, error: nil)
        } catch {
            return Outcome(scripts: scripts, error: error)
        }
    }

    // spec-example: message-composition / forward_email body types
    func testABodyThatIsNotAString_isRefusedByName_andRunsNothing() async throws {
        let rows: [(Value, Value?, String)] = [
            (.int(5), nil, "integer"),
            (.double(1.5), nil, "number"),
            (.bool(true), nil, "boolean"),
            (.array([.string("note")]), nil, "array"),
            (.object(["text": .string("note")]), nil, "object"),
            (.int(5), .bool(true), "integer"),
        ]
        for (body, flag, type) in rows {
            let outcome = try await run(body: body, flag: flag)
            // In draft mode this is the reason given too, not the bare-forward one.
            XCTAssertEqual(outcome.invalidParameter, "'body' must be a string, got: \(type)")
            XCTAssertEqual(outcome.scripts, [], "no Mail script may run for a \(type) body")
        }
    }

    // spec-example: message-composition / forward_email body types
    func testAStringThatParsesAsADataURL_isRefusedWithTheReason() async throws {
        // The SDK decodes such a JSON string into `.data`; build the value the way
        // the wire does, by decoding JSON.
        let wire = try JSONDecoder().decode(Value.self, from: Data(#""data:text/plain;base64,SGVsbG8=""#.utf8))
        guard case .data = wire else { return XCTFail("expected the SDK to decode a data: URL string as data, got \(wire)") }
        let outcome = try await run(body: wire)
        let message = try XCTUnwrap(outcome.invalidParameter)
        XCTAssertTrue(message.hasPrefix("'body' must be a string, got: data ("), message)
        XCTAssertTrue(message.contains("parses as a data: URL is decoded as binary data"), message)
        XCTAssertEqual(outcome.scripts, [])
    }

    // spec-example: message-composition / forward_email body types
    func testTheBodyIsCheckedBeforeTheAccountIsResolved() async throws {
        // Two accounts share the address, so resolving the account fails by itself.
        let mapping = ["UUID-A": "dup@example.invalid", "UUID-B": "dup@example.invalid"]
        let ambiguous = try await run(body: .string("FYI"), accountName: "dup@example.invalid", accountMapping: mapping)
        XCTAssertTrue(try XCTUnwrap(ambiguous.invalidParameter).contains("matches multiple Mail accounts"))
        XCTAssertEqual(ambiguous.scripts, [])
        // With a body of the wrong type as well, the caller is told about the body.
        let both = try await run(body: .int(5), accountName: "dup@example.invalid", accountMapping: mapping)
        XCTAssertEqual(both.invalidParameter, "'body' must be a string, got: integer")
        XCTAssertEqual(both.scripts, [])
    }

    // spec-example: message-composition / forward_email body types
    func testAMissingOrNullBody_isABareForward_whenSending_andRefusedAsADraft() async throws {
        for body in [nil, Value.null] {
            // Sending: the native forward, no keystroke. An explicit null is read
            // as leaving the key out.
            let sent = try await run(body: body)
            XCTAssertNil(sent.error)
            XCTAssertEqual(sent.scripts.count, 1)
            let script = try XCTUnwrap(sent.scripts.first)
            XCTAssertTrue(script.contains("send fwdMsg"), "bare forward: \(script.suffix(120))")
            XCTAssertFalse(script.contains("keystroke"))
            // As a draft: the bare-forward draft refusal, as before (#673).
            let draft = try await run(body: body, flag: .bool(true))
            XCTAssertTrue(try XCTUnwrap(draft.invalidParameter).contains("#673"))
            XCTAssertEqual(draft.scripts, [])
        }
    }

    // spec-example: message-composition / forward_email body types
    func testAStringBody_isPastedThenSent_theEmptyStringIncluded() async throws {
        for text in ["FYI", ""] {
            let outcome = try await run(body: .string(text))
            XCTAssertNil(outcome.error)
            XCTAssertEqual(outcome.scripts.count, 1)
            let script = try XCTUnwrap(outcome.scripts.first)
            XCTAssertFalse(script.contains("send fwdMsg"), "not the bare forward")
            // Clipboard, then the paste, then the send keystroke: a script that set
            // the clipboard and sent without pasting would lose the note.
            let clipboard = try XCTUnwrap(script.range(of: "set the clipboard to \"\(text)\""), "body \(text.debugDescription)")
            let paste = try XCTUnwrap(script.range(of: pasteKeystroke))
            let send = try XCTUnwrap(script.range(of: sendKeystroke))
            XCTAssertLessThan(clipboard.upperBound, paste.lowerBound)
            XCTAssertLessThan(paste.upperBound, send.lowerBound)
        }
    }
}
