import XCTest
import MCP
@testable import CheAppleMailMCP

/// #700 — `reply_email` reported "Reply sent successfully" while the reply was
/// still sitting in its compose window. The send script returned its success
/// label a fixed delay after the send keystroke without looking at the window
/// again. It now polls for the compose window the keystroke went to and
/// returns the label only when that window is gone; otherwise it reports an
/// unknown send state.
///
/// These are structure checks on the generated script plus behaviour checks on
/// the Swift side. The script itself is compiled (never run) by
/// `MailControllerComposeTests`' `…_compiles` tests, which cover the send form
/// of both the reply and the forward script.
final class SendConfirmedByWindowCloseTests: XCTestCase {

    private static let waitKey = "CHE_MAIL_SEND_CONFIRM_WAIT"
    private var savedWait: String?

    override func setUp() {
        super.setUp()
        savedWait = ProcessInfo.processInfo.environment[Self.waitKey]
        unsetenv(Self.waitKey)
    }

    override func tearDown() async throws {
        if let savedWait { setenv(Self.waitKey, savedWait, 1) } else { unsetenv(Self.waitKey) }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    // MARK: - script structure

    private func replyScript(draft: Bool) -> String {
        buildReplyEmailPasteScript(messageRef: "msgRef", newBody: "B", replyAll: false, saveAsDraft: draft)
    }

    private func forwardScript(draft: Bool) -> String {
        buildForwardEmailPasteScript(messageRef: "msgRef", to: ["a@example.org"], newBody: "B", saveAsDraft: draft)
    }

    private func index(of needle: String, in script: String, file: StaticString = #filePath, line: UInt = #line) -> String.Index? {
        let range = script.range(of: needle)
        XCTAssertNotNil(range, "expected \(needle.debugDescription) in the script", file: file, line: line)
        return range?.lowerBound
    }

    // spec-example: message-composition / send confirmation by window close
    func testSendingScripts_pollForTheirWindows_betweenTheDispatchAndTheSuccessLabel() throws {
        let cases: [(String, String)] = [
            (replyScript(draft: false), "return \"Reply sent successfully (paste path)\""),
            (forwardScript(draft: false), "return \"Email forwarded successfully (paste path)\""),
        ]
        for (script, label) in cases {
            let dispatch = try XCTUnwrap(index(of: "keystroke \"d\" using {command down, shift down}", in: script))
            let flag = try XCTUnwrap(index(of: "set _dispatched to true", in: script))
            let poll = try XCTUnwrap(index(of: "set _nowIds to (id of every window)", in: script))
            let unconfirmed = try XCTUnwrap(index(of: "error \"SENDUNCONFIRMED: ", in: script))
            let handler = try XCTUnwrap(index(of: "on error _mErr", in: script))
            let done = try XCTUnwrap(index(of: label, in: script))
            XCTAssertLessThan(dispatch, flag)
            XCTAssertLessThan(flag, poll, "the check runs after the keystroke was dispatched")
            XCTAssertLessThan(poll, unconfirmed)
            XCTAssertLessThan(unconfirmed, handler,
                              "the unconfirmed error is raised inside the try, so the handler marks it POSTDISPATCH")
            XCTAssertLessThan(handler, done, "the success label comes after the check")

            // The window that is watched is the front window, recorded in the
            // same Mail `tell` that has just checked it is one this call opened,
            // and before the keystroke is dispatched.
            let record = try XCTUnwrap(index(of: "set _sentWindowId to (id of front window)", in: script))
            XCTAssertLessThan(record, dispatch)
            let guardStart = try XCTUnwrap(script[..<record].range(of: "tell application \"Mail\"", options: .backwards))
            let guardBlock = String(script[guardStart.lowerBound..<record])
            XCTAssertTrue(guardBlock.contains("if (id of front window) is not in _newIds then error"), guardBlock)
            XCTAssertFalse(guardBlock.contains("end tell"), "the id is read in the tell that checked it: \(guardBlock)")
            XCTAssertEqual(script.components(separatedBy: "set _sentWindowId to").count - 1, 1)

            // Only that one window is watched (not every id in `_newIds`), and
            // only a pass that does not find it ends the loop.
            let check = String(script[flag..<handler])
            XCTAssertFalse(check.contains("_newIds"), "a viewer window opened during the first delay must not hold the result: \(check)")
            XCTAssertTrue(check.contains("if _nowIds does not contain _sentWindowId then"), check)
            XCTAssertTrue(check.contains("set _stillOpen to false\n            exit repeat"), check)
            XCTAssertTrue(check.contains("if _stillOpen then error \"SENDUNCONFIRMED: "), check)
            // The window is the user's only evidence: the check never closes it.
            XCTAssertFalse(check.contains("close "), "the check must not close a window: \(check)")
            // The handler rethrows a post-dispatch error before its cleanup branch.
            let handlerBody = String(script[handler..<done])
            let rethrow = try XCTUnwrap(handlerBody.range(of: "error \"POSTDISPATCH: \" & _mErr"))
            let cleanup = try XCTUnwrap(handlerBody.range(of: "close _cw saving no"))
            XCTAssertLessThan(rethrow.lowerBound, cleanup.lowerBound)
        }
    }

    // spec-example: message-composition / send confirmation by window close
    func testDraftScripts_haveNoConfirmationCheck_andStillCloseTheirOwnWindow() {
        let cases: [(String, String)] = [
            (replyScript(draft: true), "return \"Reply saved as draft (paste path)\""),
            (forwardScript(draft: true), "return \"Forward saved as draft (paste path)\""),
        ]
        for (script, label) in cases {
            XCTAssertFalse(script.contains("SENDUNCONFIRMED"), script)
            XCTAssertFalse(script.contains("_stillOpen"), script)
            XCTAssertFalse(script.contains("_nowIds"), script)
            XCTAssertFalse(script.contains("_sentWindowId"), script)
            XCTAssertTrue(script.contains("close _cw saving yes"))
            XCTAssertTrue(script.hasSuffix(label), "the draft row's result label: \(script.suffix(80))")
        }
    }

    // spec-example: message-composition / send confirmation wait
    func testConfirmationWait_rowsOfTheExample() {
        // (CHE_MAIL_SEND_CONFIRM_WAIT, checks, seconds named in the error)
        let rows: [(String?, Int, String)] = [
            (nil, 20, "10.0"),
            ("2", 4, "2.0"),
            ("0.6", 2, "1.0"),      // rounded up to the next 0.5 s
            ("0", 1, "0.5"),        // at least one check, so 0 still waits 0.5 s
            ("10", 20, "10.0"),
            ("99", 20, "10.0"),     // out of range: the default applies
            ("-1", 20, "10.0"),
            ("soon", 20, "10.0"),
        ]
        for (value, checks, seconds) in rows {
            if let value { setenv(Self.waitKey, value, 1) } else { unsetenv(Self.waitKey) }
            for script in [replyScript(draft: false), forwardScript(draft: false)] {
                let setting = "\(Self.waitKey)=\(value ?? "unset")"
                XCTAssertTrue(script.contains("repeat \(checks) times\n        delay 0.5\n"), setting)
                XCTAssertTrue(script.contains("was still open \(seconds) seconds after the keystroke\""), setting)
            }
        }
    }

    // MARK: - the message

    private func message(_ error: Error, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case MailError.scriptFailed(let message, let code) = error else {
            XCTFail("expected scriptFailed, got \(error)", file: file, line: line)
            return ""
        }
        XCTAssertEqual(code, -1, file: file, line: line)
        return message
    }

    private static let unconfirmed = MailError.scriptFailed(
        message: "POSTDISPATCH: SENDUNCONFIRMED: the compose window the send keystroke went to was "
            + "still open 10.0 seconds after the keystroke",
        code: -1)

    // spec-example: message-composition / unconfirmed send message
    func testUnconfirmedSend_namesTheOpenWindow_keepsUnknown_andDoesNotRetry() {
        XCTAssertTrue(isPostDispatchError(Self.unconfirmed), "the input still passes the existing gate")
        let hint = timeoutVerificationHint(.sendFlow)
        for noun in ["reply/forward", "forward"] {
            let result = unknownReplyForwardSendStateError(noun: noun, error: Self.unconfirmed)
            let text = message(result)
            XCTAssertTrue(text.contains("the compose window it went to was still open"), text)
            XCTAssertTrue(text.contains("the \(noun) has not been confirmed as sent"), text)
            XCTAssertTrue(text.contains("UNKNOWN"), text)
            XCTAssertTrue(text.contains("NOT retrying (that could send a duplicate)"), text)
            XCTAssertTrue(text.contains("Look at that compose window in Mail and at any sheet"), text)
            XCTAssertTrue(text.contains("does not show that nothing went out"), text)
            XCTAssertTrue(text.contains("let the user decide"), text)
            // It states an observation, not a verdict in either direction.
            for banned in ["safe to retry", "safe to resend", "was not sent", "not sent",
                           "has been sent", "definitely", "already on the wire", "left untouched"] {
                XCTAssertFalse(text.lowercased().contains(banned), "\(banned.debugDescription) in: \(text)")
            }
            let hintRange = text.range(of: hint)
            // Its own words (everything before the shared hint) never tell the
            // caller to send: an open window does not show the first send had
            // no effect, so "send it from there" could produce the duplicate.
            let own = String(text[..<(hintRange?.lowerBound ?? text.endIndex)]).lowercased()
            for instruction in ["send it", "send again", "resend", "re-send", "send the", "press send", "try again", "retry it"] {
                XCTAssertFalse(own.contains(instruction), "\(instruction.debugDescription) in: \(own)")
            }
            let echoRange = text.range(of: "Original error: ")
            XCTAssertNotNil(hintRange, text)
            XCTAssertNotNil(echoRange, text)
            if let hintRange, let echoRange {
                XCTAssertLessThan(hintRange.upperBound, echoRange.lowerBound,
                                  "the hint must come before the clamped echo")
            }
            XCTAssertFalse(isTimeoutError(result))
            XCTAssertFalse(isPostDispatchError(result))
        }
    }

    // spec-example: message-composition / unconfirmed send message
    func testOtherInputs_keepTheirWording() {
        let hint = timeoutVerificationHint(.sendFlow)
        for noun in ["reply/forward", "forward"] {
            // The Example's second row, input and wording both exact.
            let gone = MailError.scriptFailed(message: "POSTDISPATCH: window gone", code: -1)
            XCTAssertFalse(isUnconfirmedSendError(gone))
            XCTAssertEqual(
                message(unknownReplyForwardSendStateError(noun: noun, error: gone)),
                "the send keystroke was already dispatched but a GUI step failed afterwards — "
                    + "the send state is UNKNOWN and the \(noun) may already be on the wire. "
                    + "Check Mail's Sent mailbox / Outbox and the original thread before re-sending. "
                    + "The compose window (if still open) was left untouched for inspection. "
                    + hint
                    + " Original error: AppleScript error (-1): POSTDISPATCH: window gone")
            // The Example's third row.
            let timeout = MailError.scriptTimedOut(seconds: 90, automationGranted: true,
                                                   execution: .subprocess(exitConfirmed: true))
            XCTAssertFalse(isUnconfirmedSendError(timeout))
            XCTAssertEqual(
                message(unknownReplyForwardSendStateError(noun: noun, error: timeout)),
                "the GUI send flow hit its deadline — the send keystroke may or may "
                    + "not have fired, so the send state is UNKNOWN and the \(noun) may already "
                    + "be on the wire. NOT retrying (that could send a duplicate). Check Mail's "
                    + "Sent mailbox / Outbox, the original thread and any leftover compose window "
                    + "before re-sending. "
                    + hint
                    + " Original error: "
                    + clampedErrorEcho(timeout.localizedDescription))
        }
        // The token is matched as a prefix only: echoed mid-message, or raised
        // without the post-dispatch sentinel, it does not select the new branch.
        for text in ["POSTDISPATCH: window gone (SENDUNCONFIRMED: no)", "SENDUNCONFIRMED: no sentinel"] {
            XCTAssertFalse(isUnconfirmedSendError(MailError.scriptFailed(message: text, code: -1)), text)
        }
    }

    // spec-example: message-composition / unconfirmed send message
    func testReplyAndForward_reportAnUnconfirmedSendAsUnknown_notAsSuccess() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in throw Self.unconfirmed }, refusal: { nil })
        do {
            let result = try await MailController.shared.replyEmail(
                id: "123", mailbox: "INBOX", accountName: "a@example.org", body: "text", attachments: nil)
            XCTFail("an unconfirmed send must not be reported as \(result.debugDescription)")
        } catch {
            XCTAssertTrue(message(error).contains("the reply/forward has not been confirmed as sent"))
        }
        do {
            let result = try await MailController.shared.forwardEmail(
                id: "123", mailbox: "INBOX", accountName: "a@example.org", to: ["b@example.org"], body: "note")
            XCTFail("an unconfirmed send must not be reported as \(result.debugDescription)")
        } catch {
            XCTAssertTrue(message(error).contains("the forward has not been confirmed as sent"))
        }
    }

    // MARK: - tool descriptions

    func testToolDescriptions_sayWhatASuccessfulSendMeans() throws {
        func description(_ name: String) throws -> String {
            try XCTUnwrap(try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == name }).description)
        }
        let claim = "send is reported as sent only after the compose window the send keystroke went to has closed"
        for name in ["reply_email", "forward_email"] {
            let text = try description(name)
            XCTAssertTrue(text.contains(claim), "\(name): \(text)")
            XCTAssertTrue(text.contains("not a confirmation that the mail server accepted"), "\(name): \(text)")
            XCTAssertTrue(text.contains("a window closed by hand during the wait looks the same"), "\(name): \(text)")
            XCTAssertTrue(text.contains("unknown send state"), "\(name): \(text)")
        }
        // The forward's claim is limited to a forward with a body; the bare
        // forward runs another script that has no such check (#731).
        let forward = try description("forward_email")
        XCTAssertTrue(forward.contains("With a body, a " + claim), forward)
        XCTAssertTrue(forward.contains("A forward without a body is sent with Mail's send command and has no such check (#731)"), forward)
        XCTAssertFalse(buildForwardNoBodyScript(messageRef: "msgRef", to: ["a@example.org"]).contains("id of every window"),
                       "if the bare forward gains the check, the description's exception must go")
    }

    /// Temporary (deferred-live-verification.md): while #700's live run is
    /// outstanding, both descriptions must say so. Delete this test, and the
    /// sentence, when that run is recorded on the issue.
    func testToolDescriptions_discloseThatNoLiveSendWasRun_untilItIs() throws {
        for name in ["reply_email", "forward_email"] {
            let tool = try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == name })
            XCTAssertTrue(try XCTUnwrap(tool.description).contains("Not yet run against a live send (tracked in #700)"), name)
        }
    }
}
