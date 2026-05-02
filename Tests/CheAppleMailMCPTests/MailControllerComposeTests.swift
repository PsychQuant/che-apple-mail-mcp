import XCTest
@testable import CheAppleMailMCP

final class MailControllerComposeTests: XCTestCase {

    // MARK: - appleScriptEscape

    func testAppleScriptEscape_handlesQuotesAndNewlines() {
        XCTAssertEqual(appleScriptEscape("hello"), "hello")
        XCTAssertEqual(appleScriptEscape("say \"hi\""), "say \\\"hi\\\"")
        XCTAssertEqual(
            appleScriptEscape("line1\nline2"),
            "line1\" & return & \"line2"
        )
    }

    // MARK: - buildComposeEmailScript

    func testBuildComposeEmailScript_plainMode_omitsHTMLContent() throws {
        let script = try buildComposeEmailScript(
            to: ["a@b.c"],
            subject: "S",
            body: "Hi",
            format: .plain
        )
        XCTAssertTrue(script.contains("make new outgoing message"))
        XCTAssertTrue(script.contains("content:\"Hi\""))
        XCTAssertFalse(script.contains("html content"), "plain mode MUST NOT set html content")
    }

    func testBuildComposeEmailScript_markdownMode_setsHTMLContent() throws {
        let script = try buildComposeEmailScript(
            to: ["a@b.c"],
            subject: "S",
            body: "**bold**",
            format: .markdown
        )
        XCTAssertTrue(script.contains("set html content to"))
        XCTAssertTrue(script.contains("<strong>bold</strong>"))
    }

    func testBuildComposeEmailScript_htmlMode_passesHTMLThrough() throws {
        let script = try buildComposeEmailScript(
            to: ["a@b.c"],
            subject: "S",
            body: "<b>bold</b>",
            format: .html
        )
        XCTAssertTrue(script.contains("set html content to"))
        XCTAssertTrue(script.contains("<b>bold</b>"))
    }

    func testBuildComposeEmailScript_includesToCcBccRecipients() throws {
        let script = try buildComposeEmailScript(
            to: ["to@x.y"],
            subject: "S",
            body: "B",
            cc: ["cc@x.y"],
            bcc: ["bcc@x.y"],
            format: .plain
        )
        XCTAssertTrue(script.contains("to recipient"))
        XCTAssertTrue(script.contains("cc recipient"))
        XCTAssertTrue(script.contains("bcc recipient"))
    }

    // MARK: - buildCreateDraftScript

    func testBuildCreateDraftScript_plainMode_savesWithoutHTML() throws {
        let script = try buildCreateDraftScript(
            to: ["a@b.c"],
            subject: "S",
            body: "Hi",
            format: .plain
        )
        XCTAssertTrue(script.contains("save newMessage"))
        XCTAssertFalse(script.contains("html content"))
    }

    func testBuildCreateDraftScript_markdownMode_savesWithHTML() throws {
        let script = try buildCreateDraftScript(
            to: ["a@b.c"],
            subject: "S",
            body: "*italic*",
            format: .markdown
        )
        XCTAssertTrue(script.contains("save newMessage"))
        XCTAssertTrue(script.contains("set html content to"))
        XCTAssertTrue(script.contains("<em>italic</em>"))
    }

    func testBuildCreateDraftScript_htmlMode_embedsRawHTML() throws {
        let script = try buildCreateDraftScript(
            to: ["a@b.c"],
            subject: "S",
            body: "<a href=\"https://example.com\">link</a>",
            format: .html
        )
        XCTAssertTrue(script.contains("set html content to"))
        XCTAssertTrue(script.contains("href=\\\"https://example.com\\\""))
    }

    // MARK: - composeReplyHTML (reply/forward HTML composition)

    func testComposeReplyHTML_markdownWithOriginalHTML_usesOriginalHTML() throws {
        let result = try composeReplyHTML(
            userBody: "Thanks, noted.",
            userFormat: .markdown,
            originalHTML: "<p>Can you review?</p>",
            originalPlain: "Can you review?"
        )
        XCTAssertTrue(result.contains("Thanks, noted."), "user body must appear")
        XCTAssertTrue(result.contains("<blockquote>"), "must contain blockquote wrapper")
        XCTAssertTrue(result.contains("<p>Can you review?</p>"), "original HTML must be preserved inside blockquote")
    }

    func testComposeReplyHTML_markdownWithOnlyPlainOriginal_escapesAndWrapsInBlockquote() throws {
        let result = try composeReplyHTML(
            userBody: "Thanks.",
            userFormat: .markdown,
            originalHTML: nil,
            originalPlain: "Can you <review>?"
        )
        XCTAssertTrue(result.contains("<blockquote>"))
        XCTAssertTrue(result.contains("Can you &lt;review&gt;?"), "plain-only original must be HTML-escaped before blockquote")
    }

    func testComposeReplyHTML_htmlModeUserBodyEmbeddedVerbatim() throws {
        let result = try composeReplyHTML(
            userBody: "<p>User reply</p>",
            userFormat: .html,
            originalHTML: "<p>Original</p>",
            originalPlain: "Original"
        )
        XCTAssertTrue(result.contains("<p>User reply</p>"))
        XCTAssertTrue(result.contains("<blockquote>"))
        XCTAssertTrue(result.contains("<p>Original</p>"))
    }

    func testComposeReplyHTML_plainModeOriginalNewlinesConvertedToBR() throws {
        let result = try composeReplyHTML(
            userBody: "Reply",
            userFormat: .html,
            originalHTML: nil,
            originalPlain: "Line 1\nLine 2"
        )
        XCTAssertTrue(result.contains("<br>"), "plain-only original newlines must become <br>")
    }

    // MARK: - composeReplyPlainText (issue #43 fix)

    func testComposeReplyPlainText_prependsUserBody_quotesOriginalLines() {
        let result = composeReplyPlainText(
            userBody: "Thanks, noted.",
            originalPlain: "Can you review?\nThe deadline is Friday."
        )
        XCTAssertTrue(result.hasPrefix("Thanks, noted."), "user body must come first")
        XCTAssertTrue(result.contains("> Can you review?"), "each original line must be `> `-prefixed (RFC 3676)")
        XCTAssertTrue(result.contains("> The deadline is Friday."), "every original line must be quoted")
        XCTAssertTrue(result.contains("Thanks, noted.\n\n> "), "user body and quote block separated by blank line")
    }

    func testComposeReplyPlainText_emptyOriginal_returnsUserBodyOnly() {
        let result = composeReplyPlainText(
            userBody: "Just a heads-up.",
            originalPlain: ""
        )
        XCTAssertEqual(result, "Just a heads-up.", "empty originalPlain must NOT emit a stray quote block")
        XCTAssertFalse(result.contains("> "), "no `> ` prefix when no original to quote")
    }

    func testComposeReplyPlainText_originalWithEmptyLines_keepsQuotedEmptyLines() {
        let result = composeReplyPlainText(
            userBody: "Reply",
            originalPlain: "Para 1\n\nPara 2"
        )
        // RFC 3676 §4.5: quoted empty lines emit `>` only (no trailing space stuffing
        // when there is no content). Round-1 hardening (#43 verify Logic #3).
        XCTAssertTrue(result.contains("> Para 1"))
        XCTAssertTrue(result.contains("> Para 2"))
        XCTAssertTrue(result.contains(">\n"), "blank quoted lines must remain prefixed (with bare `>`)")
        XCTAssertFalse(result.contains("> \n"), "blank quoted lines MUST NOT have trailing-space stuffing (RFC 3676 §4.5)")
    }

    func testComposeReplyPlainText_originalWithCRLF_normalizesLineEndings() {
        // Round-1 hardening (#43 verify Logic #5 / Codex P1): Mail.app IMAP /
        // Exchange messages return CRLF line endings. The helper must normalize
        // them so the AppleScript escape doesn't smuggle stray `\r` through.
        let result = composeReplyPlainText(
            userBody: "Reply",
            originalPlain: "Line 1\r\nLine 2\r\nLine 3"
        )
        XCTAssertTrue(result.contains("> Line 1"))
        XCTAssertTrue(result.contains("> Line 2"))
        XCTAssertTrue(result.contains("> Line 3"))
        XCTAssertFalse(result.contains("\r"), "CRLF / CR characters MUST be normalized to LF before quoting")
    }

    func testComposeReplyPlainText_originalWithSingleNewline_returnsUserBodyOnly() {
        // Round-1 hardening (#43 verify Logic #1 / Codex P3): Mail.app sometimes
        // returns "\n" or "\n\n" as the plain content for HTML-only messages.
        // Treat as no-quotable-content rather than emitting stray `>` lines.
        XCTAssertEqual(composeReplyPlainText(userBody: "Hi", originalPlain: "\n"), "Hi")
        XCTAssertEqual(composeReplyPlainText(userBody: "Hi", originalPlain: "\n\n\n"), "Hi")
        XCTAssertEqual(composeReplyPlainText(userBody: "Hi", originalPlain: "\r\n"), "Hi")
    }

    func testComposeReplyPlainText_originalWithTrailingNewline_dropsStrayQuoteLine() {
        // Round-1 hardening (#43 verify Logic #2): Mail.app commonly appends a
        // trailing newline. Without trim, the helper would emit `> ` (with
        // trailing space) as a stray last quote line.
        let result = composeReplyPlainText(
            userBody: "Reply",
            originalPlain: "Body line\n"
        )
        XCTAssertTrue(result.hasSuffix("> Body line"), "result MUST end at the last real quoted line, no stray `> ` afterwards")
        XCTAssertFalse(result.contains("> \n"), "trailing newline MUST NOT produce a `> ` (with trailing space) stray line")
    }

    // MARK: - buildReplyEmailScript

    func testBuildReplyEmailScript_plainMode_includesQuotedOriginal() throws {
        // Issue #43 fix: plain branch now Swift-side composes the quoted body
        // (RFC 3676 `> ` prefix) instead of relying on the broken
        // `& return & return & content` AppleScript pattern, which silently
        // produced bare-body replies because Mail.app does not populate the
        // outgoing message's `content` until the GUI compose window materializes.
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "Reply body",
            userFormat: .plain,
            replyAll: false,
            originalHTML: nil,
            originalPlain: "Original line 1\nOriginal line 2"
        )
        XCTAssertTrue(script.contains("set content to"), "plain mode still uses `set content to`")
        XCTAssertTrue(script.contains("> Original line 1"), "quoted original line must appear in the script literal")
        XCTAssertTrue(script.contains("> Original line 2"), "every original line must be quoted")
        XCTAssertFalse(script.contains("& return & return & content"), "broken AppleScript `& content` pattern MUST be removed (#43)")
        XCTAssertFalse(script.contains("html content"), "plain mode MUST NOT touch html content")
        XCTAssertFalse(script.contains("<blockquote>"), "plain mode MUST NOT wrap in blockquote (HTML tag)")
    }

    func testBuildReplyEmailScript_plainMode_emptyOriginal_omitsQuoteBlock() throws {
        // Edge case for #43: when no original content was pre-fetched (e.g.
        // pre-fetch failed or original is empty), do NOT emit a stray `> ` line.
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "Reply body",
            userFormat: .plain,
            replyAll: false,
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("set content to"), "plain mode still uses `set content to`")
        XCTAssertTrue(script.contains("Reply body"), "user body must appear")
        XCTAssertFalse(script.contains("> "), "empty originalPlain MUST NOT emit `> ` quote prefix")
        XCTAssertFalse(script.contains("& return & return & content"), "broken AppleScript `& content` pattern MUST be removed (#43)")
    }

    func testBuildReplyEmailScript_markdownMode_setsHTMLContentWithBlockquote() throws {
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "Thanks, noted.",
            userFormat: .markdown,
            replyAll: false,
            originalHTML: "<p>Can you review?</p>",
            originalPlain: "Can you review?"
        )
        XCTAssertTrue(script.contains("set html content to"))
        XCTAssertTrue(script.contains("<blockquote>"), "non-plain reply script MUST contain <blockquote>")
        XCTAssertTrue(script.contains("Thanks, noted."))
    }

    func testBuildReplyEmailScript_replyAll_usesReplyAllVerb() throws {
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: true,
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("reply all originalMsg"))
    }

    // MARK: - buildReplyEmailScript: cc_additional / attachments / save_as_draft (issue #33)

    func testBuildReplyEmailScript_ccAdditional_emitsCCRecipientFragment() throws {
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            ccAdditional: ["a@b.com", "c@d.com"],
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("make new cc recipient"), "cc_additional MUST emit AppleScript cc recipient fragments")
        XCTAssertTrue(script.contains("a@b.com"))
        XCTAssertTrue(script.contains("c@d.com"))
    }

    func testBuildReplyEmailScript_attachments_emitsAttachmentFragment() throws {
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            attachments: ["/tmp/cv.pdf", "/tmp/cert.pdf"],
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("make new attachment"), "attachments MUST emit AppleScript attachment fragment")
        XCTAssertTrue(script.contains("POSIX file \"/tmp/cv.pdf\""))
        XCTAssertTrue(script.contains("POSIX file \"/tmp/cert.pdf\""))
    }

    func testBuildReplyEmailScript_saveAsDraft_replacesSendWithSave() throws {
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            saveAsDraft: true,
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("save replyMsg"), "save_as_draft=true MUST emit `save replyMsg`")
        XCTAssertFalse(script.contains("send replyMsg"), "save_as_draft=true MUST NOT emit `send replyMsg`")
        XCTAssertTrue(script.contains("\"Reply saved as draft\""), "draft mode MUST report `Reply saved as draft`")
    }

    func testBuildReplyEmailScript_backwardCompat_defaultsPreserveSendBehavior() throws {
        // No new params -> behavior must be byte-identical to v0.1.x send-immediate path
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("send replyMsg"), "default behavior MUST send (backward compat)")
        XCTAssertFalse(script.contains("save replyMsg"))
        XCTAssertFalse(script.contains("make new cc recipient"))
        XCTAssertFalse(script.contains("make new attachment"))
        XCTAssertTrue(script.contains("\"Reply sent successfully\""))
    }

    func testBuildReplyEmailScript_htmlMode_alsoSupportsCcAttachmentsSave() throws {
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "Thanks.",
            userFormat: .html,
            replyAll: false,
            ccAdditional: ["x@y.z"],
            attachments: ["/tmp/a.pdf"],
            saveAsDraft: true,
            originalHTML: "<p>Can you review?</p>",
            originalPlain: "Can you review?"
        )
        XCTAssertTrue(script.contains("set html content to"), "html branch should still set html content")
        XCTAssertTrue(script.contains("make new cc recipient"), "html branch must also support cc_additional")
        XCTAssertTrue(script.contains("make new attachment"), "html branch must also support attachments")
        XCTAssertTrue(script.contains("save replyMsg"), "html branch must also support save_as_draft")
        XCTAssertFalse(script.contains("send replyMsg"))
    }

    // MARK: - buildReplyEmailScript: window-popup behavior (issue #33 verify finding A)

    func testBuildReplyEmailScript_saveAsDraft_usesWithoutOpeningWindow() throws {
        // saveAsDraft=true should NOT pop the Mail.app reply window — the user
        // wanted a quiet draft; popping a window invites them to edit it
        // directly and lose the saved snapshot.
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            saveAsDraft: true,
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("without opening window"), "save_as_draft=true MUST use `without opening window`")
        XCTAssertFalse(script.contains("with opening window"), "save_as_draft=true MUST NOT use `with opening window`")
    }

    func testBuildReplyEmailScript_sendPath_keepsWithOpeningWindow() throws {
        // Send path (default) should keep `with opening window` — backward compat.
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("with opening window"), "send path MUST keep `with opening window` (backward compat)")
        XCTAssertFalse(script.contains("without opening window"))
    }

    func testBuildReplyEmailScript_htmlMode_saveAsDraft_alsoUsesWithoutOpeningWindow() throws {
        // html branch must mirror plain branch's window-clause behavior.
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "Thanks.",
            userFormat: .html,
            replyAll: false,
            saveAsDraft: true,
            originalHTML: "<p>orig</p>",
            originalPlain: "orig"
        )
        XCTAssertTrue(script.contains("without opening window"), "html branch save_as_draft=true MUST use `without opening window`")
        XCTAssertFalse(script.contains("with opening window"))
    }

    // MARK: - buildForwardEmailScript

    func testBuildForwardEmailScript_plainMode_withBody_keepsConcatenation() throws {
        let script = try buildForwardEmailScript(
            messageRef: "msgRef",
            to: ["x@y.z"],
            userBody: "FYI",
            userFormat: .plain,
            originalHTML: nil,
            originalPlain: nil
        )
        XCTAssertTrue(script.contains("forward originalMsg"))
        XCTAssertTrue(script.contains("to recipient"))
        XCTAssertTrue(script.contains("set content to"))
        XCTAssertTrue(script.contains("& return & return & content"))
        XCTAssertFalse(script.contains("html content"))
    }

    func testBuildForwardEmailScript_htmlMode_withBody_setsHTMLContentWithBlockquote() throws {
        let script = try buildForwardEmailScript(
            messageRef: "msgRef",
            to: ["x@y.z"],
            userBody: "<p>Forwarding</p>",
            userFormat: .html,
            originalHTML: "<p>Original</p>",
            originalPlain: "Original"
        )
        XCTAssertTrue(script.contains("set html content to"))
        XCTAssertTrue(script.contains("<blockquote>"))
    }

    func testBuildForwardEmailScript_noBody_omitsContentMutation() throws {
        let script = try buildForwardEmailScript(
            messageRef: "msgRef",
            to: ["x@y.z"],
            userBody: nil,
            userFormat: .plain,
            originalHTML: nil,
            originalPlain: nil
        )
        XCTAssertTrue(script.contains("forward originalMsg"))
        XCTAssertFalse(script.contains("set content to"))
        XCTAssertFalse(script.contains("set html content to"))
    }

    // MARK: - parseFetchedOriginalContent

    func testParseFetchedOriginalContent_bothFieldsSeparated() {
        let raw = "<p>html</p>\u{001E}\u{001E}\u{001E}plain text"
        let parsed = parseFetchedOriginalContent(raw)
        XCTAssertEqual(parsed.html, "<p>html</p>")
        XCTAssertEqual(parsed.plain, "plain text")
    }

    func testParseFetchedOriginalContent_emptyHTMLReturnsNil() {
        let raw = "\u{001E}\u{001E}\u{001E}plain only"
        let parsed = parseFetchedOriginalContent(raw)
        XCTAssertNil(parsed.html)
        XCTAssertEqual(parsed.plain, "plain only")
    }
}
