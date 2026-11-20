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

    /// No Envelope Index and no account lookup: `account_name` has no "@".
    private func makeToolServer() async throws -> CheAppleMailMCPServer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try await CheAppleMailMCPServer(
            databasePath: root.appendingPathComponent("missing.sqlite").path,
            initialSync: false, classificationDirectory: root)
    }

    /// Runs the tool through the MCP handler. `body` and `flag` are left out of
    /// the arguments when nil, so "missing" really is missing.
    private func run(body: Value?, flag: Value? = nil) async throws -> [String] {
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: { script in scripts.append(script); return "ok" },
                                                 refusal: { nil })
        var arguments: [String: Value] = [
            "id": .string("123"), "mailbox": .string("INBOX"), "account_name": .string("Work"),
            "to": .array([.string("me@example.invalid")]),
        ]
        if let body { arguments["body"] = body }
        if let flag { arguments["save_as_draft"] = flag }
        defer { RefusedRun.scripts = scripts.count }
        _ = try await makeToolServer().executeToolCall(name: "forward_email", arguments: arguments)
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
    func testAMissingOrNullBody_isStillABareForward_andAStringStillPastes() async throws {
        for body in [nil, Value.null] {
            let scripts = try await run(body: body)
            XCTAssertEqual(scripts.count, 1)
            XCTAssertTrue(scripts[0].contains("send fwdMsg"), "bare forward: \(scripts[0].suffix(120))")
            XCTAssertFalse(scripts[0].contains("keystroke"))
        }
        let pasted = try await run(body: .string("FYI"))
        XCTAssertEqual(pasted.count, 1)
        XCTAssertTrue(pasted[0].contains("set the clipboard to \"FYI\""))
        XCTAssertTrue(pasted[0].contains("keystroke \"d\" using {command down, shift down}"))
    }
}
