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

    // MARK: - buildReplyEmailScript

    func testBuildReplyEmailScript_plainMode_keepsAmpersandConcatenation() throws {
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "Reply body",
            userFormat: .plain,
            replyAll: false,
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("set content to"))
        XCTAssertTrue(script.contains("& return & return & content"), "plain mode MUST keep existing concatenation semantics")
        XCTAssertFalse(script.contains("html content"), "plain mode MUST NOT touch html content")
        XCTAssertFalse(script.contains("<blockquote>"), "plain mode MUST NOT wrap in blockquote")
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
