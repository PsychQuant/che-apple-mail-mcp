import XCTest
import MCP
@testable import CheAppleMailMCP

/// #674 — `forward_email` read its optional `body` leniently, so a body that was
/// present but not a string was treated as no body: without `save_as_draft` the
/// forward went out bare, without the note the caller supplied.
///
/// No live Mail action here: every Mail script goes through the test seam.
final class ForwardBodyTypeTests: XCTestCase {

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

    /// Runs the tool through the MCP handler. `body` and `flag` are left out of
    /// the arguments when nil, so "missing" really is missing.
    private func run(body: Value?, flag: Value? = nil, accountName: String = "Work",
                     accountMapping: [String: String]? = nil) async throws -> [String] {
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: { script in scripts.append(script); return "ok" },
                                                 refusal: { nil })
        var arguments: [String: Value] = [
            "id": .string("123"), "mailbox": .string("INBOX"), "account_name": .string(accountName),
            "to": .array([.string("me@example.invalid")]),
        ]
        if let body { arguments["body"] = body }
        if let flag { arguments["save_as_draft"] = flag }
        defer { RefusedRun.scripts = scripts.count }
        _ = try await makeToolServer(accountMapping: accountMapping)
            .executeToolCall(name: "forward_email", arguments: arguments)
        return scripts
    }

    /// The number of scripts the last `run` saw, readable after it threw.
    private enum RefusedRun { nonisolated(unsafe) static var scripts = 0 }

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
            do {
                _ = try await run(body: body, flag: flag)
                XCTFail("a \(type) body must be refused")
            } catch MailError.invalidParameter(let message) {
                XCTAssertEqual(message, "'body' must be a string, got: \(type)")
                // In draft mode this is the reason given, not the bare-forward one.
                XCTAssertFalse(message.contains("without a body"), message)
            }
            XCTAssertEqual(RefusedRun.scripts, 0, "no Mail script may run for a \(type) body")
        }
    }

    // spec-example: message-composition / forward_email body types
    func testAStringThatParsesAsADataURL_isRefusedWithTheReason() async throws {
        // The SDK decodes such a JSON string into `.data`; build the value the way
        // the wire does, by decoding JSON.
        let wire = try JSONDecoder().decode(Value.self, from: Data(#""data:text/plain;base64,SGVsbG8=""#.utf8))
        guard case .data = wire else { return XCTFail("expected the SDK to decode a data: URL string as data, got \(wire)") }
        do {
            _ = try await run(body: wire)
            XCTFail("a data: URL body must be refused")
        } catch MailError.invalidParameter(let message) {
            XCTAssertTrue(message.hasPrefix("'body' must be a string, got: data ("), message)
            XCTAssertTrue(message.contains("parses as a data: URL is decoded as binary data"), message)
        }
        XCTAssertEqual(RefusedRun.scripts, 0)
    }

    // spec-example: message-composition / forward_email body types
    func testTheBodyIsCheckedBeforeTheAccountIsResolved() async throws {
        // Two accounts share the address, so resolving the account fails by itself.
        let mapping = ["UUID-A": "dup@example.invalid", "UUID-B": "dup@example.invalid"]
        do {
            _ = try await run(body: .string("FYI"), accountName: "dup@example.invalid", accountMapping: mapping)
            XCTFail("the ambiguous account must be refused")
        } catch MailError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("matches multiple Mail accounts"), message)
        }
        XCTAssertEqual(RefusedRun.scripts, 0)
        // With a body of the wrong type as well, the caller is told about the body.
        do {
            _ = try await run(body: .int(5), accountName: "dup@example.invalid", accountMapping: mapping)
            XCTFail("a non-string body must be refused")
        } catch MailError.invalidParameter(let message) {
            XCTAssertEqual(message, "'body' must be a string, got: integer")
        }
        XCTAssertEqual(RefusedRun.scripts, 0)
    }

    // spec-example: message-composition / forward_email body types
    func testAMissingOrNullBody_isStillABareForward_andAStringStillPastes() async throws {
        let sendKeystroke = "keystroke \"d\" using {command down, shift down}"
        for body in [nil, Value.null] {
            let scripts = try await run(body: body)
            XCTAssertEqual(scripts.count, 1)
            let script = try XCTUnwrap(scripts.first)
            XCTAssertTrue(script.contains("send fwdMsg"), "bare forward: \(script.suffix(120))")
            XCTAssertFalse(script.contains("keystroke"))
        }
        // A string pastes as before, the empty string included.
        for text in ["FYI", ""] {
            let scripts = try await run(body: .string(text))
            XCTAssertEqual(scripts.count, 1)
            let script = try XCTUnwrap(scripts.first)
            XCTAssertTrue(script.contains("set the clipboard to \"\(text)\""), "body \(text.debugDescription)")
            XCTAssertTrue(script.contains(sendKeystroke))
            XCTAssertFalse(script.contains("send fwdMsg"))
        }
    }
}
