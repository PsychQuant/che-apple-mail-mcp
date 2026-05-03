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

    func testBuildForwardEmailScript_plainMode_withBody_includesQuotedOriginal() throws {
        // Issue #44 (mirrors #43 fix): plain forward must embed the quoted
        // original via Swift-side composeReplyPlainText helper, not the broken
        // `& content` AppleScript pattern. See #43 closing summary for root cause.
        let script = try buildForwardEmailScript(
            messageRef: "msgRef",
            to: ["x@y.z"],
            userBody: "FYI",
            userFormat: .plain,
            originalHTML: nil,
            originalPlain: "Original line 1\nOriginal line 2"
        )
        XCTAssertTrue(script.contains("forward originalMsg"))
        XCTAssertTrue(script.contains("to recipient"))
        XCTAssertTrue(script.contains("set content to"))
        XCTAssertTrue(script.contains("> Original line 1"), "quoted original must appear in script")
        XCTAssertTrue(script.contains("> Original line 2"), "every original line must be quoted")
        XCTAssertFalse(script.contains("& return & return & content"), "broken `& content` AppleScript pattern MUST be removed (#44)")
        XCTAssertFalse(script.contains("html content"), "plain mode MUST NOT touch html content")
    }

    func testBuildForwardEmailScript_plainMode_emptyOriginal_omitsQuoteBlock() throws {
        // Edge case mirror of #43: when pre-fetch returns empty originalPlain
        // (e.g. message deleted, sandbox error, or no body to forward), do NOT
        // emit a stray `> ` line. Helper composeReplyPlainText handles this via
        // its isEmpty/whitespace-only guard.
        let script = try buildForwardEmailScript(
            messageRef: "msgRef",
            to: ["x@y.z"],
            userBody: "FYI",
            userFormat: .plain,
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("set content to"))
        XCTAssertTrue(script.contains("FYI"))
        XCTAssertFalse(script.contains("> "), "empty originalPlain MUST NOT emit `> ` quote prefix")
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

    // MARK: - validateEmailAddresses (#41)

    func testValidateEmailAddresses_acceptsValid() async throws {
        try await MailController.shared.validateEmailAddresses(
            ["a@b.com", "user.name+tag@example.co.uk", "用戶@xn--wgv71a.com"],
            field: "to"
        )
    }

    func testValidateEmailAddresses_emptyArrayIsNoop() async throws {
        try await MailController.shared.validateEmailAddresses([], field: "cc")
    }

    func testValidateEmailAddresses_rejectsControlChars() async {
        // Header injection attempt: \n in address could try to inject Bcc: header.
        do {
            try await MailController.shared.validateEmailAddresses(
                ["ok@x.com\nBcc: leak@evil.com"],
                field: "cc_additional"
            )
            XCTFail("expected control-char rejection")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("control characters"), "msg must mention control chars: \(msg)")
            XCTAssertTrue(msg.contains("cc_additional"), "msg must include field name: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testValidateEmailAddresses_rejectsMissingAt() async {
        do {
            try await MailController.shared.validateEmailAddresses(["not-an-email"], field: "to")
            XCTFail("expected reject")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("exactly one '@'"), "msg must explain: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - validateAttachmentPaths (#38)

    /// Helper to assert validation throws MailError.invalidParameter with a recognizable fragment.
    private func assertAttachmentRejected(_ paths: [String],
                                          containing fragment: String,
                                          envAllowList: String? = nil,
                                          file: StaticString = #file, line: UInt = #line) async {
        if let env = envAllowList {
            setenv("MAIL_MCP_ATTACHMENT_ROOTS", env, 1)
            addTeardownBlock { unsetenv("MAIL_MCP_ATTACHMENT_ROOTS") }
        }
        do {
            try await MailController.shared.validateAttachmentPaths(paths)
            XCTFail("expected validation to throw, paths=\(paths)", file: file, line: line)
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected MailError.invalidParameter, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(msg.contains(fragment),
                          "error '\(msg)' must contain '\(fragment)'",
                          file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertAttachmentAccepted(_ paths: [String],
                                          envAllowList: String? = nil,
                                          file: StaticString = #file, line: UInt = #line) async {
        if let env = envAllowList {
            setenv("MAIL_MCP_ATTACHMENT_ROOTS", env, 1)
            addTeardownBlock { unsetenv("MAIL_MCP_ATTACHMENT_ROOTS") }
        }
        do {
            try await MailController.shared.validateAttachmentPaths(paths)
        } catch {
            XCTFail("expected validation to accept paths=\(paths), got error: \(error)",
                    file: file, line: line)
        }
    }

    func testValidateAttachmentPaths_emptyArrayIsNoop() async throws {
        // Defensive: empty array short-circuits, no env var lookup, no FileManager hit.
        try await MailController.shared.validateAttachmentPaths([])
    }

    func testValidateAttachmentPaths_acceptsRegularTempFile() async throws {
        let tmp = "/tmp/che-apple-mail-test-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data("ok".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        await assertAttachmentAccepted([tmp])
    }

    func testValidateAttachmentPaths_rejectsNonexistent() async {
        let bogus = "/tmp/does-not-exist-\(UUID().uuidString).pdf"
        await assertAttachmentRejected([bogus], containing: "not found")
    }

    func testValidateAttachmentPaths_rejectsSshDirectory() async throws {
        // We can't rely on actual ~/.ssh/id_ed25519 existing in test env. Create a
        // probe file in HOME/.ssh and assert deny-list catches it. If HOME/.ssh
        // doesn't exist or isn't writable, fall back to asserting that any path
        // _under_ ~/.ssh would be rejected (helper compares prefix, file existence
        // is checked first so we need a real file).
        let home = NSHomeDirectory()
        let sshProbe = "\(home)/.ssh/che-apple-mail-test-probe-\(UUID().uuidString).txt"
        // Try to create — if can't, skip
        let parent = "\(home)/.ssh"
        guard FileManager.default.isWritableFile(atPath: parent) ||
              ((try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)) != nil),
              FileManager.default.createFile(atPath: sshProbe, contents: Data("probe".utf8)) else {
            throw XCTSkip("Cannot create probe file under ~/.ssh in test env")
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: sshProbe) }
        await assertAttachmentRejected([sshProbe], containing: ".ssh")
    }

    func testValidateAttachmentPaths_rejectsSystemPath() async {
        // /etc/hosts always exists on macOS; under deny-list "/etc".
        await assertAttachmentRejected(["/etc/hosts"], containing: "/etc")
    }

    func testValidateAttachmentPaths_resolvesSymlinkBeforeCheck() async throws {
        // Create symlink in /tmp pointing to /etc/hosts (deny-listed).
        // Without symlink resolution, the path "/tmp/symlink" looks safe (under /tmp)
        // and bypasses deny-list. With resolution, the resolved path is /etc/hosts
        // and gets rejected.
        let symlink = "/tmp/che-apple-mail-test-symlink-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: "/etc/hosts")
        addTeardownBlock { try? FileManager.default.removeItem(atPath: symlink) }
        await assertAttachmentRejected([symlink], containing: "/etc")
    }

    func testValidateAttachmentPaths_envAllowList_acceptsAllowed() async throws {
        let tmp = "/tmp/che-apple-mail-allow-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data("ok".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        await assertAttachmentAccepted([tmp], envAllowList: "/tmp")
    }

    func testValidateAttachmentPaths_envAllowList_rejectsOutsideAllowed() async throws {
        // /tmp is not in env allow-list "/var/folders" — should reject even though
        // /tmp itself isn't deny-listed.
        let tmp = "/tmp/che-apple-mail-deny-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data("ok".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        await assertAttachmentRejected([tmp], containing: "MAIL_MCP_ATTACHMENT_ROOTS",
                                        envAllowList: "/Users/nonexistent-allow-root")
    }

    func testValidateAttachmentPaths_multiplePaths_collectsAllFailures() async {
        // /etc/hosts (system deny) + bogus nonexistent. Both should be in error msg.
        let bogus = "/tmp/missing-\(UUID().uuidString).pdf"
        do {
            try await MailController.shared.validateAttachmentPaths(["/etc/hosts", bogus])
            XCTFail("expected validation to throw")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected MailError.invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("/etc"), "msg must mention /etc rejection: \(msg)")
            XCTAssertTrue(msg.contains("not found"), "msg must mention bogus path not found: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - validateEmailAddresses (#41) — continued

    func testValidateEmailAddresses_rejectsMultipleAt() async {
        do {
            try await MailController.shared.validateEmailAddresses(["a@b@c.com"], field: "to")
            XCTFail("expected reject")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else { return XCTFail() }
            XCTAssertTrue(msg.contains("exactly one '@'"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testValidateEmailAddresses_rejectsAtAtBoundaries() async {
        for bogus in ["@nodomain.com", "noprefix@", "@", ""] {
            do {
                try await MailController.shared.validateEmailAddresses([bogus], field: "to")
                XCTFail("expected reject for '\(bogus)'")
            } catch is MailError {
                // expected
            } catch {
                XCTFail("unexpected error type for '\(bogus)': \(error)")
            }
        }
    }

    func testValidateEmailAddresses_collectsAllFailures() async {
        do {
            try await MailController.shared.validateEmailAddresses(
                ["a@b@c.com", "valid@x.com", "bad"],
                field: "to"
            )
            XCTFail("expected reject")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else { return XCTFail() }
            // Both invalid addresses should appear in error message; valid one should not.
            XCTAssertTrue(msg.contains("a@b@c.com"), "msg must list a@b@c.com: \(msg)")
            XCTAssertTrue(msg.contains("'bad'"), "msg must list 'bad': \(msg)")
            XCTAssertFalse(msg.contains("'valid@x.com'"), "msg must NOT list valid address: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - dedupAddresses (#34)

    func testDedupAddresses_removesCaseInsensitiveDuplicates() async {
        let result = await MailController.shared.dedupAddresses(
            ["a@b.com", "A@B.COM", "c@d.com", "a@b.com"]
        )
        XCTAssertEqual(result, ["a@b.com", "c@d.com"], "first-seen wins; case-insensitive dedup")
    }

    func testDedupAddresses_emptyArray() async {
        let result = await MailController.shared.dedupAddresses([])
        XCTAssertEqual(result, [])
    }

    func testDedupAddresses_singleAddress() async {
        let result = await MailController.shared.dedupAddresses(["a@b.com"])
        XCTAssertEqual(result, ["a@b.com"])
    }

    func testDedupAddresses_preservesFirstSeenOrder() async {
        // Order matters for downstream recipientFragment generation.
        let result = await MailController.shared.dedupAddresses(
            ["c@d.com", "a@b.com", "C@D.com", "b@e.com"]
        )
        XCTAssertEqual(result, ["c@d.com", "a@b.com", "b@e.com"])
    }

    // MARK: - Large originalPlain script size (#49)

    /// Issue #49: defensive coverage for long-thread scenarios. After
    /// composeReplyPlainText emits `> `-prefixed lines + appleScriptEscape mangles
    /// each `\n` to `& return &` (12-char expansion), large originalPlain could
    /// approach macOS osascript's stack-derived script size limit (~64 KB
    /// historically). This test asserts a 14 KB original (200 lines × ~70 chars)
    /// still produces a script under 32 KB after escape mangling.
    func testComposeReplyPlainText_largeOriginal_doesNotExplode() {
        let original = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing.\n", count: 200)
        XCTAssertGreaterThan(original.count, 10_000, "test fixture must be ≥10 KB to be meaningful")
        let result = composeReplyPlainText(userBody: "Reply", originalPlain: original)
        XCTAssertLessThan(result.count, 32_000, "composed body must fit comfortably in osascript limits")
        // Verify the helper still produces a useful first quoted line.
        XCTAssertTrue(result.contains("> Lorem ipsum"), "helper must still produce `> ` quoted lines for large originals")
    }

    func testBuildReplyEmailScript_largeOriginal_scriptUnderOsascriptLimit() throws {
        // 500 lines × ~12 chars = ~6 KB raw original.
        // After appleScriptEscape mangles 500 newlines (each into 12-char `& return &`),
        // adds +6 KB → ~14 KB script. Still safely under any osascript ceiling.
        let original = String(repeating: "Lorem ipsum.\n", count: 500)
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "Reply",
            userFormat: .plain,
            replyAll: false,
            originalHTML: nil,
            originalPlain: original
        )
        XCTAssertLessThan(script.count, 32_000, "generated AppleScript must fit within osascript limits")
        XCTAssertTrue(script.contains("> Lorem ipsum"), "script must still contain quoted lines")
    }

    // MARK: - attachmentFragment race-condition mitigation (issue #60)

    func testAttachmentFragment_multipleAttachments_emitsDelayBetweenEveryPair() throws {
        // 3 attachments → exactly 2 `delay 0.3` lines between the 3 `make new attachment` lines.
        // Mitigates Mail.app AppleScript race where `at after the last paragraph` resolves stale
        // before the previous attachment binds.
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            attachments: ["/tmp/a.pdf", "/tmp/b.pdf", "/tmp/c.pdf"],
            originalHTML: nil,
            originalPlain: ""
        )
        let attachmentLineCount = script.components(separatedBy: "make new attachment").count - 1
        let delayBetweenCount = script.components(separatedBy: "delay 0.3").count - 1
        XCTAssertEqual(attachmentLineCount, 3, "3 attachments must emit 3 attachment lines")
        XCTAssertEqual(delayBetweenCount, 2, "3 attachments must emit exactly 2 `delay 0.3` lines (one between each pair)")
    }

    func testAttachmentFragment_multipleAttachments_emitsTrailingDelayBeforeDispatch() throws {
        // N >= 2 → exactly one `delay 0.5` after the last attachment, before save/send commits.
        // Ensures async attachment pipeline drains before save/send (#60 second mechanism).
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            attachments: ["/tmp/a.pdf", "/tmp/b.pdf"],
            originalHTML: nil,
            originalPlain: ""
        )
        let trailingDelayCount = script.components(separatedBy: "delay 0.5").count - 1
        XCTAssertEqual(trailingDelayCount, 1, "N>=2 attachments must emit exactly 1 trailing `delay 0.5`")
        // Trailing delay must come AFTER the last attachment line and BEFORE the dispatch keyword.
        guard let lastAttachIdx = script.range(of: "make new attachment", options: .backwards),
              let trailingDelayIdx = script.range(of: "delay 0.5"),
              let dispatchIdx = script.range(of: "send replyMsg") ?? script.range(of: "save replyMsg") else {
            XCTFail("script missing expected anchors")
            return
        }
        XCTAssertLessThan(lastAttachIdx.lowerBound, trailingDelayIdx.lowerBound,
                          "trailing `delay 0.5` must appear after the last `make new attachment`")
        XCTAssertLessThan(trailingDelayIdx.lowerBound, dispatchIdx.lowerBound,
                          "trailing `delay 0.5` must appear before the dispatch (send/save) keyword")
    }

    func testAttachmentFragment_singleAttachment_emitsNoDelay() throws {
        // N == 1 has no race to mitigate (no second attachment to compete with).
        // Don't penalize the common path with unnecessary latency.
        let script = try buildReplyEmailScript(
            messageRef: "msgRef",
            userBody: "B",
            userFormat: .plain,
            replyAll: false,
            attachments: ["/tmp/only.pdf"],
            originalHTML: nil,
            originalPlain: ""
        )
        XCTAssertTrue(script.contains("make new attachment"), "single attachment still emits attachment line")
        XCTAssertFalse(script.contains("delay 0.3"), "N=1 must NOT emit `delay 0.3` (no race at N=1)")
        XCTAssertFalse(script.contains("delay 0.5"), "N=1 must NOT emit trailing `delay 0.5` (no need to drain pipeline for single attachment)")
    }

    func testAttachmentFragment_composeBuilder_alsoMitigatesRace() throws {
        // Same fix must apply through buildComposeEmailScript (3 callers all share the helper).
        let script = try buildComposeEmailScript(
            to: ["x@y.z"],
            subject: "S",
            body: "B",
            attachments: ["/tmp/a.pdf", "/tmp/b.pdf"]
        )
        XCTAssertTrue(script.contains("delay 0.3"), "compose builder must inherit the race fix")
        XCTAssertTrue(script.contains("delay 0.5"), "compose builder must inherit the trailing drain delay")
    }

    func testAttachmentFragment_draftBuilder_alsoMitigatesRace() throws {
        // Same fix must apply through buildCreateDraftScript.
        let script = try buildCreateDraftScript(
            to: ["x@y.z"],
            subject: "S",
            body: "B",
            attachments: ["/tmp/a.pdf", "/tmp/b.pdf"]
        )
        XCTAssertTrue(script.contains("delay 0.3"), "draft builder must inherit the race fix")
        XCTAssertTrue(script.contains("delay 0.5"), "draft builder must inherit the trailing drain delay")
    }
}
