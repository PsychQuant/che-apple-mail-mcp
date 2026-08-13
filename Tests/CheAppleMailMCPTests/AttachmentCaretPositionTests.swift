import XCTest
@testable import CheAppleMailMCP

/// #341 / #321 — attachments landed at the START of the body instead of the end.
///
/// Reported twice from live use before the cause was found: #321 (2026-07-31)
/// described the position, #341 (2026-08-07) supplied the mechanism and a
/// screenshot showing the PDF icon to the LEFT of the first line, ahead of the
/// salutation. For a formal letter that is the first thing the recipient sees.
///
/// Mail's File ▸ Attach (⇧⌘A) inserts at the **current insertion point**, and
/// after the mailto hand-off fills the body the caret sits at its start. The
/// script never moved it, so every attachment went in ahead of the text.
final class AttachmentCaretPositionTests: XCTestCase {

    private func script(attachments: [String]) -> String {
        buildMailtoComposeScript(
            url: "mailto:a@b.co?subject=Hi&body=Hello",
            subject: "Hi",
            attachments: attachments,
            send: false)
    }

    /// ⌘↓ — "move to end of document" in a Cocoa text view, locale-independent
    /// like the other shortcuts on this path.
    private let caretToEnd = "key code 125 using {command down}"
    private let attachKey = "keystroke \"a\" using {command down, shift down}"

    func testCaretIsMovedToTheEndBeforeAnyAttachment() throws {
        let s = script(attachments: ["/tmp/report.pdf"])
        let caret = try XCTUnwrap(s.range(of: caretToEnd)?.lowerBound,
            "the caret must be moved to the body end — without it ⇧⌘A inserts "
            + "wherever mailto left the insertion point, which is the start")
        let attach = try XCTUnwrap(s.range(of: attachKey)?.lowerBound,
            "the attach shortcut must still be emitted")
        XCTAssertTrue(caret < attach, "moving the caret AFTER attaching would not help")
    }

    func testCaretMoveIsEmittedOnceRegardlessOfAttachmentCount() {
        let s = script(attachments: ["/tmp/a.pdf", "/tmp/b.pdf", "/tmp/c.pdf"])
        XCTAssertEqual(s.components(separatedBy: caretToEnd).count - 1, 1,
            "after the first attach the caret is already past the body; repeating "
            + "the move would be harmless but would misstate the intent")
        XCTAssertEqual(s.components(separatedBy: attachKey).count - 1, 3,
            "one File ▸ Attach cycle per attachment")
    }

    func testNoCaretMoveWhenThereIsNothingToAttach() {
        XCTAssertFalse(script(attachments: []).contains(caretToEnd),
            "a draft with no attachments must not have its insertion point moved — "
            + "the user's caret position is theirs")
    }

    func testTheAttachFlowIsOtherwiseUnchanged() {
        let s = script(attachments: ["/tmp/report.pdf"])
        XCTAssertTrue(s.contains("keystroke \"g\" using {command down, shift down}"),
                      "⇧⌘G go-to-folder must survive")
        XCTAssertTrue(s.contains("set the clipboard to \"/tmp/report.pdf\""),
                      "the path is still pasted, not typed (#220)")
    }
}
