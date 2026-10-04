import XCTest
@testable import CheAppleMailMCP

/// #472 — the orchestration seams of the experimental direct-draft path that
/// need no store and no Mail: the trigger script and the early exits.
final class DirectDraftPathTests: XCTestCase {

    func testTriggerScriptWaitsForTheDraftThenTogglesItsReadStatus() {
        let s = buildDirectDraftTriggerScript(rowId: 305619)
        XCTAssertTrue(s.contains("first message of drafts mailbox whose id is 305619"))
        XCTAssertTrue(s.contains("repeat 40 times"), "wait up to 10 s for Mail to list the new draft")
        XCTAssertTrue(s.contains("DIRECTDRAFT: Mail did not list the new draft"))
        let off = try! XCTUnwrap(s.range(of: "set read status of _m to false"))
        let on = try! XCTUnwrap(s.range(of: "set read status of _m to true"))
        XCTAssertTrue(off.upperBound < on.lowerBound, "false, then true: a net no-op that wakes the sync engine")
        XCTAssertFalse(s.contains("whose content contains"), "#221: never a full-content scan")
        XCTAssertTrue(s.contains("delay 0.5"), "the gap validated in #463 Round 2 (0.3 s left one draft unread)")
    }

    func testReadRepairScriptMarksTheDraftRead() {
        // #472 live: with a 0.3 s gap one of two drafts ended unread locally
        // (server read=1). After the upload the path re-asserts read status.
        let s = buildDirectDraftMarkReadScript(rowId: 305742)
        XCTAssertTrue(s.contains("first message of drafts mailbox whose id is 305742"))
        XCTAssertTrue(s.contains("set read status of _m to true"))
        XCTAssertFalse(s.contains("to false"))
    }

    func testDisabledFlagIsNotAttemptedAndAddsNoNote() async {
        let outcome = await DirectDraftPath(controller: MailController.shared, reader: nil, enabled: false)
            .attempt(to: ["a@example.org"], subject: "S", body: "B", cc: nil, bcc: nil,
                     attachments: nil, format: .plain, fromAddress: "me@example.org")
        XCTAssertEqual(outcome, .notAttempted(nil), "with the flag off the GUI path runs exactly as before")
    }

    func testIneligibleCallNamesTheReasonBeforeTouchingAnything() async {
        let outcome = await DirectDraftPath(controller: MailController.shared, reader: nil, enabled: true)
            .attempt(to: ["a@example.org"], subject: "S", body: "B", cc: ["c@example.org"], bcc: nil,
                     attachments: nil, format: .plain, fromAddress: "me@example.org")
        XCTAssertEqual(outcome, .notAttempted(DirectDraft.Ineligible.ccOrBcc.reason))
    }

    func testFallbackNoteFormat() {
        XCTAssertEqual(DirectDraftPath.fallbackNote("cc/bcc are not written directly"),
                       " [experimental direct-write not used: cc/bcc are not written directly — GUI path]")
    }
}
