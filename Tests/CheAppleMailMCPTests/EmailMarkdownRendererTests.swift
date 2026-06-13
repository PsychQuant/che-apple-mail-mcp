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
        textBody: String? = "Body line one.\n\n> quoted reply\n--JP"
    ) -> EmailContent {
        EmailContent(
            subject: subject, sender: sender, toRecipients: to, ccRecipients: cc,
            date: date, messageId: messageId, textBody: textBody, htmlBody: nil, rawSource: nil
        )
    }

    func testRender_coreFrontmatterFields_presentAndOrdered() {
        let md = EmailMarkdownRenderer.render(makeEmail(), direction: "received", inReplyTo: "")
        let lines = md.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "---")
        XCTAssertEqual(lines[1], "message_id: \"<CAKM2gv@mail.gmail.com>\"")
        XCTAssertEqual(lines[2], "thread_key: \"4 papers using MB3.5\"")
        XCTAssertEqual(lines[3], "in_reply_to: \"\"")
        XCTAssertEqual(lines[4], "date: 2026-06-13T08:01:14Z")
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

    func testRfc822ToISO8601UTC() {
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601UTC("Sat, 13 Jun 2026 16:01:14 +0800"),
            "2026-06-13T08:01:14Z", "Taiwan +0800 must convert to UTC")
        XCTAssertEqual(
            EmailMarkdownRenderer.rfc822ToISO8601UTC("Sun, 3 May 2026 01:09:32 +0000"),
            "2026-05-03T01:09:32Z")
        // Unparseable → passthrough (never drop data)
        XCTAssertEqual(EmailMarkdownRenderer.rfc822ToISO8601UTC("not a date"), "not a date")
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
}
