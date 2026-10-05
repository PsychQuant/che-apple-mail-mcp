import XCTest
@testable import CheAppleMailMCP

/// #464 — replace fixed waits with readiness polls where a condition exists.
///
/// Per-step timing of three default `create_draft` calls (median ms since the
/// previous step) put 1850 ms on the window wait, 747 ms on the delay after
/// clicking the From popup, and 1375 ms on picking + verifying the sender, out
/// of ~7.95 s. A delay sweep showed the window wait could drop to 0.2 s with
/// the draft still correct, but a 0 s step delay failed the sender read-back:
/// the popup value updates asynchronously. So the window wait and the read-back
/// wait become polls on the condition they stood in for, with the old delay (or
/// more) as the cap — a run that succeeded before cannot fail now. The wait after
/// clicking the popup was also tried as a poll and kept (see its test).
final class ComposeReadinessPollTests: XCTestCase {

    private func script(from: String? = "me@corp.example") -> String {
        buildMailtoComposeScript(url: "mailto:a@x?subject=S", subject: "S", attachments: [],
                                 send: false, fromAddress: from, timing: false)
    }

    private func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return nil }
        return String(s[ra.upperBound..<rb.lowerBound])
    }

    func testWindowIsPolledWithTheOldDelayAsTheCap() throws {
        let s = script()
        let wait = try XCTUnwrap(between(s, "mailto \"mailto:a@x?subject=S\"",
                                         "if (count of windows) <= _wc then error"))
        XCTAssertFalse(wait.contains("\n    delay 1.8\n"), "the fixed 1.8 s wait must be gone")
        XCTAssertTrue(wait.contains("delay 0.1"), "poll in 0.1 s steps")
        XCTAssertTrue(wait.contains("_winWaited ≥ 1.8"), "the old window delay is the cap")
        XCTAssertTrue(wait.contains("if _ourMatches > 0 then exit repeat"),
                      "stop as soon as our new, subject-titled window exists")
    }

    func testWindowChecksAndMessagesAreUnchangedAfterThePoll() {
        let s = script()
        for message in ["mailto did not open a compose window",
                        "could not identify our new compose window by subject after mailto (nothing sent)",
                        "more than one new window is titled the subject"] {
            XCTAssertTrue(s.contains(message), "failure semantics must stay: \(message)")
        }
    }

    func testTheWaitAfterOpeningThePopupStays() throws {
        // Removing it was tried and reverted (#464 live, 5 runs): the menu poll
        // then ran while the menu was still opening — one run spent 5987 ms in
        // it and one failed with a System Events connection error. With the
        // wait the poll took ~100 ms in every run.
        let s = script()
        let gap = try XCTUnwrap(between(s, "click _fromPopup", "set _miTotal to 0"))
        XCTAssertTrue(gap.contains("delay 0.7"), "the wait between the click and the menu poll must stay")
    }

    func testTheFirstPopupClickIsRetriedWithAFreshLookup() throws {
        // #464 live: with the window found ~0.1 s after mailto (instead of after a
        // fixed 1.8 s), the first click on the From popup failed in 3 of 10 runs
        // with "System Events: connection error" while Mail was still setting up
        // the compose window; the value reads just before it had succeeded.
        let s = script()
        let block = try XCTUnwrap(between(s, "SENDERPOPUP: From popup (AXIdentifier popup_from) not found",
                                          "set _miTotal to 0"))
        XCTAssertTrue(block.contains("repeat with _clickTry from 1 to 4"), "bounded retry")
        XCTAssertTrue(block.contains("on error _clickErrNow"), "a failed click is caught")
        XCTAssertTrue(block.contains("(value of attribute \"AXIdentifier\" of _pb) is \"popup_from\""),
                      "the popup is looked up again before retrying")
        XCTAssertTrue(block.contains("SENDERPOPUP: could not open the From popup"),
                      "exhausting the retries stays a pre-dispatch SENDERPOPUP failure")
    }

    func testSenderReadbackIsPolledUntilItMatches() throws {
        let s = script()
        let tail = try XCTUnwrap(between(s, "click _pickedItem", "SENDERPOPUP: read-back mismatch"))
        XCTAssertFalse(tail.contains("\n                delay 0.7\n"), "no fixed wait before reading back")
        XCTAssertTrue(tail.contains("repeat 20 times"), "poll up to 2 s (old: 0.7 s, then one read)")
        XCTAssertTrue(tail.contains("my senderMatches(_senderReadback, \"me@corp.example\")"))
        XCTAssertTrue(tail.contains("delay 0.1"))
        XCTAssertTrue(s.contains("not (my senderMatches(_senderReadback, \"me@corp.example\"))"),
                      "the final exact check and its error stay")
    }

    func testPathWithoutSenderStillPollsTheWindow() {
        let s = script(from: nil)
        XCTAssertTrue(s.contains("_winWaited ≥ 1.8"))
        XCTAssertFalse(s.contains("_fromPopup"))
    }
}
