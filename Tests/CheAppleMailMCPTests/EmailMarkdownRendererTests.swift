import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

final class EmailMarkdownRendererTests: XCTestCase {

    private func makeEmail(
        subject: String = "Re: 4 papers using MB3.5",
        sender: String = "Joanne Peng <peng.cyj@gmail.com>",
        to: [String] = ["Li-Ting Chen <litingc@unr.edu>"],
        cc: [String] = [],
        date: String = "Sat, 13 Jun 2026 16:01:14 +0800",
        messageId: String = "<CAKM2gv@mail.gmail.com>",
        inReplyTo: String = "",
        textBody: String? = "Body line one.\n\n> quoted reply\n--JP"
    ) -> EmailContent {
        EmailContent(
            subject: subject, sender: sender, toRecipients: to, ccRecipients: cc,
            date: date, messageId: messageId, inReplyTo: inReplyTo,
            textBody: textBody, htmlBody: nil, rawSource: nil
        )
    }

    func testRender_coreFrontmatterFields_presentAndOrdered() {
        let md = EmailMarkdownRenderer.render(makeEmail(), direction: "received", inReplyTo: "")
        let lines = md.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "---")
        XCTAssertEqual(lines[1], "message_id: \"<CAKM2gv@mail.gmail.com>\"")
        XCTAssertEqual(lines[2], "thread_key: \"4 papers using MB3.5\"")
        XCTAssertEqual(lines[3], "in_reply_to: \"\"")
        XCTAssertEqual(lines[4], "date: 2026-06-13T16:01:14+08:00")
        XCTAssertEqual(lines[5], "sender: peng.cyj@gmail.com")
        XCTAssertEqual(lines[6], "direction: received")
        XCTAssertEqual(lines[7], "---")
    }

    func testRender_ccOmittedWhenEmpty_includedWhenPresent() {
        let noCc = EmailMarkdownRenderer.render(makeEmail(cc: []), direction: "received", inReplyTo: "")
        XCTAssertFalse(noCc.contains("\nCc:"), "Cc line must be omitted when there is no cc")

        let withCc = EmailMarkdownRenderer.render(
            makeEmail(cc: ["a@x.com", "b@y.com"]), direction: "received", inReplyTo: "")
        XCTAssertTrue(withCc.contains("Cc: a@x.com, b@y.com"))
    }

    func testStripReplyPrefixes() {
        XCTAssertEqual(EmailMarkdownRenderer.stripReplyPrefixes("Re: hello"), "hello")
        XCTAssertEqual(EmailMarkdownRenderer.stripReplyPrefixes("RE: Fwd: nested"), "nested")
        XCTAssertEqual(EmailMarkdownRenderer.stripReplyPrefixes("轉寄: 中文主旨"), "中文主旨")
        XCTAssertEqual(EmailMarkdownRenderer.stripReplyPrefixes("no prefix"), "no prefix")
    }

    func testBareEmail() {
        XCTAssertEqual(EmailMarkdownRenderer.bareEmail("Joanne Peng <peng.cyj@gmail.com>"), "peng.cyj@gmail.com")
        XCTAssertEqual(EmailMarkdownRenderer.bareEmail("plain@addr.com"), "plain@addr.com")
        XCTAssertEqual(EmailMarkdownRenderer.bareEmail("  Spaced <X@Y.COM> "), "x@y.com")
    }

    func testRfc822ToISO8601_preservesNumericOffset() {
        // #244 — the frontmatter date must agree with the body `Date:` line:
        // keep the original numeric UTC offset instead of converting to Z.
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("Sat, 13 Jun 2026 16:01:14 +0800"),
            "2026-06-13T16:01:14+08:00", "Taiwan +0800 must keep its offset (same instant)")
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("Mon, 13 Jul 2026 16:49:57 +0800"),
            "2026-07-13T16:49:57+08:00", "the #244 reported example")
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("Wed, 1 Jul 2026 09:15:00 -0530"),
            "2026-07-01T09:15:00-05:30", "negative half-hour offsets survive")
    }

    func testRfc822ToISO8601_zeroOffsetRendersZ() {
        // +0000 / -0000 keep the historical Z rendering (byte-identical to the
        // pre-#244 output for UTC mail).
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("Sun, 3 May 2026 01:09:32 +0000"),
            "2026-05-03T01:09:32Z")
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("Sun, 3 May 2026 01:09:32 -0000"),
            "2026-05-03T01:09:32Z")
    }

    func testRfc822ToISO8601_namedZoneFallsBackToUTC() {
        // Named zones (RFC 5322 obsolete syntax) carry no reliable numeric
        // offset token — fall back to the historical UTC rendering.
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("Sat, 13 Jun 2026 16:01:14 GMT"),
            "2026-06-13T16:01:14Z")
    }

    func testRfc822ToISO8601_trailingCommentStripped_offsetStillPreserved() {
        // #244 verify (DA corpus scan: 3.2% of live mail) — RFC 2822 obsolete
        // trailing comments (Outlook/Exchange `(CST)`, Gmail `(UTC)`) must not
        // defeat parsing or offset extraction.
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("Mon, 13 Jul 2026 16:49:57 +0800 (CST)"),
            "2026-07-13T16:49:57+08:00", "trailing comment must be ignored, offset preserved")
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("Sun, 3 May 2026 01:09:32 +0000 (UTC)"),
            "2026-05-03T01:09:32Z", "Gmail-style +0000 (UTC) renders the historical Z")
        // A comment on an otherwise-unparseable date: passthrough returns the
        // ORIGINAL string (comment included) — never drop data.
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601("garbage (CST)"), "garbage (CST)")
    }

    func testRfc822ToISO8601_unparseablePassesThrough() {
        // Unparseable → passthrough (never drop data)
        XCTAssertEqual(EmailMarkdownRenderer.rfc822ToISO8601("not a date"), "not a date")
        XCTAssertEqual(EmailMarkdownRenderer.rfc822ToISO8601(""), "")
    }

    func testRender_verbatimBodyPreserved() {
        let body = "Top message.\n\n> quoted layer 1\n>> quoted layer 2\n\n--\nSignature block"
        let md = EmailMarkdownRenderer.render(
            makeEmail(textBody: body), direction: "received", inReplyTo: "")
        XCTAssertTrue(md.hasSuffix(body), "body must be appended verbatim, no trimming/rewrite")
    }

    func testRender_extraFrontmatterAppended() {
        let md = EmailMarkdownRenderer.render(
            makeEmail(), direction: "sent", inReplyTo: "<parent@x>",
            extraFrontmatter: [("archived_by", "export_emails_markdown")])
        XCTAssertTrue(md.contains("in_reply_to: \"<parent@x>\""))
        XCTAssertTrue(md.contains("direction: sent"))
        XCTAssertTrue(md.contains("archived_by: \"export_emails_markdown\""))
    }

    func testYamlQuoted_replacesEmbeddedDoubleQuote() {
        let md = EmailMarkdownRenderer.render(
            makeEmail(subject: "Re: the \"quoted\" topic"), direction: "received", inReplyTo: "")
        XCTAssertTrue(md.contains("thread_key: \"the 'quoted' topic\""),
                      "embedded double-quotes must become single-quotes to keep YAML parseable")
    }

    func testRender_newlineInFrontmatterValuesCannotInjectYAML() {
        // A sender-controlled header with a newline must not break out of its
        // YAML line and inject a spurious frontmatter key.
        let md = EmailMarkdownRenderer.render(
            makeEmail(subject: "Topic\ninjected_subj: evil",
                      messageId: "<m>\ninjected_mid: evil"),
            direction: "received", inReplyTo: "")
        let frontmatter = md.components(separatedBy: "---\n")[1]  // between the two fences
        XCTAssertFalse(frontmatter.contains("\ninjected_subj:"),
                       "newline in subject must be flattened, not injected as a YAML key")
        XCTAssertFalse(frontmatter.contains("\ninjected_mid:"),
                       "newline in message_id must be flattened, not injected as a YAML key")
        // Core fields still present and well-formed.
        XCTAssertTrue(frontmatter.contains("thread_key: \"Topic injected_subj: evil\""))
        XCTAssertTrue(frontmatter.contains("date: 2026-06-13T16:01:14+08:00"))
    }

    func testRfc822ToISO8601_crossMidnight_datePartIsSenderLocal() {
        // #244 — 00:30 +0800 is 16:30 UTC the PREVIOUS day. The `YYYY-MM-DD`
        // prefix (which the export filename takes via prefix(10)) must be the
        // sender-local calendar date, consistent with the body Date: line.
        let iso = EmailMarkdownRenderer.rfc822ToISO8601("Mon, 14 Jul 2026 00:30:00 +0800")
        XCTAssertEqual(iso, "2026-07-14T00:30:00+08:00")
        XCTAssertEqual(String(iso.prefix(10)), "2026-07-14",
                       "filename date must be sender-local, not the UTC date 2026-07-13")
    }

    func testFrontmatterDate_andFilenameDate_shareOneHelper() throws {
        // Three-way coherence (#244): frontmatter `date`, the manifest/index
        // value, and the filename `YYYY-MM-DD` all derive from the same
        // rfc822ToISO8601 output. Assert the render path agrees with the
        // helper, and pin (via source scan) that the export filename path
        // calls the same helper rather than growing its own conversion.
        let md = EmailMarkdownRenderer.render(
            makeEmail(date: "Mon, 14 Jul 2026 00:30:00 +0800"),
            direction: "received", inReplyTo: "")
        XCTAssertTrue(md.contains("date: 2026-07-14T00:30:00+08:00"))

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/ExportEmailsMarkdown.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("EmailMarkdownRenderer.rfc822ToISO8601(content.date)"),
            "export filename/manifest date must come from the shared helper (#244)")
        XCTAssertFalse(source.contains("rfc822ToISO8601UTC"),
                       "no call site may keep the removed UTC-pinned helper name")
    }

    func testFilenameDatePart_completeCalendarDateOrUnknown() {
        // #244 verify — a passthrough raw header must never leak a fragment
        // ("13" from "Mon, 13 Jul …") into the filename.
        XCTAssertEqual(ExportEmailsMarkdown.filenameDatePart(fromISO: "2026-07-13T16:49:57+08:00"),
                       "2026-07-13")
        XCTAssertEqual(ExportEmailsMarkdown.filenameDatePart(fromISO: "2026-05-03T01:09:32Z"),
                       "2026-05-03")
        XCTAssertEqual(ExportEmailsMarkdown.filenameDatePart(fromISO: "Mon, 13 Jul 2026 16:49:57 +0800 (CST)"),
                       "unknown-date")
        XCTAssertEqual(ExportEmailsMarkdown.filenameDatePart(fromISO: ""), "unknown-date")
    }

    func testSingleLine_flattensControlChars() {
        XCTAssertEqual(EmailMarkdownRenderer.singleLine("a\nb\tc"), "a b c")
        XCTAssertEqual(EmailMarkdownRenderer.singleLine("  trimmed\r\n"), "trimmed")
        XCTAssertEqual(EmailMarkdownRenderer.singleLine("plain@addr.com"), "plain@addr.com")
    }
}
