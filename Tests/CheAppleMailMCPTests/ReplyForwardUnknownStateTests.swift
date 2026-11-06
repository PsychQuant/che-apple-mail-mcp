import XCTest
@testable import CheAppleMailMCP

/// #522 — `reply_email` / `forward_email` used to build their unknown-send-state
/// message inline, twice, with no test on either copy. The message now comes from
/// `unknownReplyForwardSendStateError`; the send-flow hint sits before the
/// clamped echo.
///
/// #550 — a timeout used to get the post-dispatch wording ("the send keystroke
/// was already dispatched"), which over-claims: the GUI script did not finish,
/// so the keystroke may not have fired. A timeout now gets compose's wording;
/// the post-dispatch wording is pinned byte for byte for every other input.
final class ReplyForwardUnknownStateTests: XCTestCase {

    private static let executions: [ScriptTimeoutExecution] = [
        .inProcess, .subprocess(exitConfirmed: true), .subprocess(exitConfirmed: false),
    ]

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
                let hintRange = text.range(of: timeoutVerificationHint(.sendFlow))
                let echoRange = text.range(of: "Original error: ")
                XCTAssertNotNil(hintRange, text)
                if let hintRange, let echoRange {
                    XCTAssertLessThan(hintRange.upperBound, echoRange.lowerBound,
                                      "the hint must come before the clamped echo")
                }
            }
        }
    }

    /// Any input that is not a timeout keeps the post-dispatch wording unchanged.
    func testWording_nonTimeout_isTheInlineTextPlusTheSendFlowHintBeforeTheEcho() {
        let input = MailError.scriptFailed(message: "boom", code: -1)
        XCTAssertFalse(isTimeoutError(input), "this test pins the non-timeout branch")
        // Both nouns the production sites pass (#550 verify).
        for noun in ["reply/forward", "forward"] {
            let text = message(unknownReplyForwardSendStateError(noun: noun, error: input))
            XCTAssertEqual(
                text,
                "the send keystroke was already dispatched but a GUI step failed afterwards — "
                    + "the send state is UNKNOWN and the \(noun) may already be on the wire. "
                    + "Check Mail's Sent mailbox / Outbox and the original thread before re-sending. "
                    + "The compose window (if still open) was left untouched for inspection. "
                    + timeoutVerificationHint(.sendFlow)
                    + " Original error: AppleScript error (-1): boom")
        }
    }

    /// #550 — a timeout does not claim the keystroke fired.
    func testTimeout_saysTheKeystrokeMayOrMayNotHaveFired_andKeepsTheGate() {
        let hint = timeoutVerificationHint(.sendFlow)
        for noun in ["reply/forward", "forward"] {
            for execution in Self.executions {
                let input = MailError.scriptTimedOut(seconds: 90, automationGranted: true, execution: execution)
                XCTAssertTrue(isTimeoutError(input))
                let result = unknownReplyForwardSendStateError(noun: noun, error: input)
                let text = message(result)
                XCTAssertTrue(text.contains("the send keystroke may or may not have fired"), text)
                XCTAssertFalse(text.contains("already dispatched"), text)
                XCTAssertTrue(text.contains("UNKNOWN"), text)
                XCTAssertTrue(text.contains("NOT retrying (that could send a duplicate)"), text)
                XCTAssertTrue(text.contains("the \(noun) may already be on the wire"), text)
                XCTAssertTrue(text.contains("the original thread"), text)
                XCTAssertTrue(text.contains("any leftover compose window"), text)
                XCTAssertFalse(text.contains("left untouched"),
                               "after a timeout the script was terminated; nothing is known about the window: \(text)")
                let hintRange = text.range(of: hint)
                let echoRange = text.range(of: "Original error: ")
                XCTAssertNotNil(hintRange, "the whole hint must be present: \(text)")
                XCTAssertNotNil(echoRange, text)
                if let hintRange, let echoRange {
                    XCTAssertLessThan(hintRange.upperBound, echoRange.lowerBound,
                                      "the hint must come before the clamped echo")
                }
                // The produced error is not itself a timeout or a post-dispatch error.
                XCTAssertFalse(isTimeoutError(result))
                XCTAssertFalse(isPostDispatchError(result))
            }
        }
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

    func testReplyAndForward_throughTheSeam_reportUnknown_withTheHint_andRunTheScriptOnce() async throws {
        let hint = timeoutVerificationHint(.sendFlow)
        let cases: [(MailError, expected: String, absent: String)] = [
            (MailError.scriptFailed(message: "POSTDISPATCH: window gone mid-send", code: -1),
             "the send keystroke was already dispatched", "may or may not have fired"),
            (timeout(), "the send keystroke may or may not have fired", "already dispatched"),
        ]
        for (failure, expected, absent) in cases {
            var calls = 0
            await MailController.shared.setTestSeams(
                scriptRunner: { _ in calls += 1; throw failure }, refusal: { nil })
            do {
                _ = try await MailController.shared.replyEmail(
                    id: "123", mailbox: "INBOX", accountName: "me@example.invalid", body: "text",
                    attachments: nil)
                XCTFail("reply must throw")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("UNKNOWN"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(hint), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains(absent), error.localizedDescription)
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
                XCTAssertTrue(error.localizedDescription.contains(hint), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains(absent), error.localizedDescription)
            }
            XCTAssertEqual(calls, 1, "nothing retries a send")
        }
    }
}
