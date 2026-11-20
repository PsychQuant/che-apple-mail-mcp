import XCTest
import MCP
@testable import CheAppleMailMCP

/// #700 — `reply_email` reported "Reply sent successfully" while the reply was
/// still sitting in its compose window. The send script returned its success
/// label a fixed delay after the send keystroke without looking at the window
/// again. It now polls for the windows it opened and returns the label only
/// when they are gone; otherwise it reports an unknown send state.
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

            // The check compares against the ids this call opened, and only
            // a pass that finds none of them ends the loop.
            let check = String(script[flag..<handler])
            XCTAssertTrue(check.contains("repeat with _nid in _newIds"), check)
            XCTAssertTrue(check.contains("if _nowIds contains (contents of _nid) then set _stillOpen to true"), check)
            XCTAssertTrue(check.contains("if not _stillOpen then exit repeat"), check)
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
        for script in [replyScript(draft: true), forwardScript(draft: true)] {
            XCTAssertFalse(script.contains("SENDUNCONFIRMED"), script)
            XCTAssertFalse(script.contains("_stillOpen"), script)
            XCTAssertFalse(script.contains("_nowIds"), script)
            XCTAssertTrue(script.contains("close _cw saving yes"))
        }
    }

    // spec-example: message-composition / send confirmation by window close
    func testConfirmationWait_defaultsToTenSeconds_andIsBoundedByTheEnvironment() {
        // 0.5 s between checks; at least one check always runs.
        let expectations: [(String?, String)] = [
            (nil, "repeat 20 times"),
            ("2", "repeat 4 times"),
            ("0.6", "repeat 2 times"),
            ("0", "repeat 1 times"),
            ("10", "repeat 20 times"),
            ("99", "repeat 20 times"),      // out of range: the default applies
            ("-1", "repeat 20 times"),
            ("soon", "repeat 20 times"),
        ]
        for (value, expected) in expectations {
            if let value { setenv(Self.waitKey, value, 1) } else { unsetenv(Self.waitKey) }
            for script in [replyScript(draft: false), forwardScript(draft: false)] {
                XCTAssertTrue(script.contains(expected + "\n"),
                              "\(Self.waitKey)=\(value ?? "unset") should give \(expected.debugDescription)")
                XCTAssertTrue(script.contains("delay 0.5\n"))
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
        message: "POSTDISPATCH: SENDUNCONFIRMED: a compose window this call opened was still open "
            + "10.0 seconds after the send keystroke",
        code: -1)

    // spec-example: message-composition / unconfirmed send message
    func testUnconfirmedSend_namesTheOpenWindow_keepsUnknown_andDoesNotRetry() {
        XCTAssertTrue(isPostDispatchError(Self.unconfirmed), "the input still passes the existing gate")
        let hint = timeoutVerificationHint(.sendFlow)
        for noun in ["reply/forward", "forward"] {
            let result = unknownReplyForwardSendStateError(noun: noun, error: Self.unconfirmed)
            let text = message(result)
            XCTAssertTrue(text.contains("compose window this call opened was still open"), text)
            XCTAssertTrue(text.contains("the \(noun) has not been confirmed as sent"), text)
            XCTAssertTrue(text.contains("UNKNOWN"), text)
            XCTAssertTrue(text.contains("NOT retrying (that could send a duplicate)"), text)
            XCTAssertTrue(text.contains("Look at that compose window in Mail"), text)
            // It states an observation, not a verdict in either direction.
            for banned in ["safe to retry", "safe to resend", "was not sent", "not sent",
                           "has been sent", "definitely", "already on the wire", "left untouched"] {
                XCTAssertFalse(text.lowercased().contains(banned), "\(banned.debugDescription) in: \(text)")
            }
            let hintRange = text.range(of: hint)
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
        // A post-dispatch error that merely mentions the token is not this case.
        let other = MailError.scriptFailed(message: "POSTDISPATCH: window gone (SENDUNCONFIRMED: no)", code: -1)
        let otherText = message(unknownReplyForwardSendStateError(noun: "forward", error: other))
        XCTAssertTrue(otherText.hasPrefix("the send keystroke was already dispatched but a GUI step failed afterwards"),
                      otherText)
        let timeout = MailError.scriptTimedOut(seconds: 90, automationGranted: true,
                                               execution: .subprocess(exitConfirmed: true))
        let timeoutText = message(unknownReplyForwardSendStateError(noun: "forward", error: timeout))
        XCTAssertTrue(timeoutText.hasPrefix("the GUI send flow hit its deadline"), timeoutText)
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
            XCTAssertTrue(message(error).contains("compose window this call opened was still open"))
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
        for name in ["reply_email", "forward_email"] {
            let tool = try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == name })
            let text = try XCTUnwrap(tool.description)
            XCTAssertTrue(text.contains("only after the compose window this call opened has closed"), "\(name): \(text)")
            XCTAssertTrue(text.contains("not a confirmation that the mail server accepted"), "\(name): \(text)")
            XCTAssertTrue(text.contains("unknown send state"), "\(name): \(text)")
            XCTAssertTrue(text.contains("Not yet run against a live send (tracked in #700)"), "\(name): \(text)")
        }
    }
}
