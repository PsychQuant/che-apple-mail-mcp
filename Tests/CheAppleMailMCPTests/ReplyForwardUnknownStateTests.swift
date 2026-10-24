import XCTest
@testable import CheAppleMailMCP

/// #522 — `reply_email` / `forward_email` used to build their unknown-send-state
/// message inline, twice, with no test on either copy. The message now comes from
/// `unknownReplyForwardSendStateError`; these tests pin its current wording so the
/// extraction cannot change it. Rewording the over-claim ("already dispatched" on
/// a timeout) belongs to #550, not here.
final class ReplyForwardUnknownStateTests: XCTestCase {

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    private func timeout() -> MailError {
        .scriptTimedOut(seconds: 90, automationGranted: true, execution: .subprocess(exitConfirmed: true))
    }

    private func message(_ error: MailError, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case MailError.scriptFailed(let message, let code) = error else {
            XCTFail("expected scriptFailed, got \(error)", file: file, line: line)
            return ""
        }
        XCTAssertEqual(code, -1, file: file, line: line)
        return message
    }

    func testNamesTheNoun_keepsUnknown_andEchoesTheOriginalError() {
        let inputs: [Error] = [
            timeout(),
            MailError.scriptFailed(message: "POSTDISPATCH: window gone", code: -1),
        ]
        for noun in ["reply/forward", "forward"] {
            for input in inputs {
                let text = message(unknownReplyForwardSendStateError(noun: noun, error: input))
                XCTAssertTrue(text.contains("the \(noun) may already be on the wire"), text)
                XCTAssertTrue(text.contains("UNKNOWN"), text)
                XCTAssertTrue(text.contains("before re-sending"), text)
                XCTAssertTrue(text.contains("Original error: "), text)
            }
        }
    }

    func testWording_isByteForByteTheTextTheInlineCopiesHad() {
        let text = message(unknownReplyForwardSendStateError(
            noun: "forward", error: MailError.scriptFailed(message: "boom", code: -1)))
        XCTAssertEqual(
            text,
            "the send keystroke was already dispatched but a GUI step failed afterwards — "
                + "the send state is UNKNOWN and the forward may already be on the wire. "
                + "Check Mail's Sent mailbox / Outbox and the original thread before re-sending. "
                + "The compose window (if still open) was left untouched for inspection. "
                + "Original error: AppleScript error (-1): boom")
    }

    func testEchoStaysClamped() {
        let huge = MailError.scriptFailed(message: String(repeating: "x", count: 5000), code: -1)
        let text = message(unknownReplyForwardSendStateError(noun: "forward", error: huge))
        let echo = text.components(separatedBy: "Original error: ").last ?? ""
        XCTAssertEqual(echo.count, 200)
    }

    func testProductionSites_replyAndForward_useTheSharedHelper() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("unknownReplyForwardSendStateError(noun: \"reply/forward\", error: error)"))
        XCTAssertTrue(source.contains("unknownReplyForwardSendStateError(noun: \"forward\", error: error)"))
        XCTAssertFalse(source.contains("the send keystroke was already dispatched but a GUI step failed"),
                       "the inline copies of the reply/forward message must be gone")
    }

    func testReplyAndForward_throughTheSeam_reportUnknown_andRunTheScriptOnce() async throws {
        for failure in [
            MailError.scriptFailed(message: "POSTDISPATCH: window gone mid-send", code: -1),
            timeout(),
        ] {
            var calls = 0
            await MailController.shared.setTestSeams(
                scriptRunner: { _ in calls += 1; throw failure }, refusal: { nil })
            do {
                _ = try await MailController.shared.replyEmail(
                    id: "123", mailbox: "INBOX", accountName: "me@example.invalid", body: "text")
                XCTFail("reply must throw")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("UNKNOWN"), error.localizedDescription)
            }
            XCTAssertEqual(calls, 1, "nothing retries a send")

            calls = 0
            do {
                _ = try await MailController.shared.forwardEmail(
                    id: "123", mailbox: "INBOX", accountName: "me@example.invalid",
                    to: ["peer@example.invalid"], body: "note")
                XCTFail("forward must throw")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("UNKNOWN"), error.localizedDescription)
            }
            XCTAssertEqual(calls, 1, "nothing retries a send")
        }
    }
}
