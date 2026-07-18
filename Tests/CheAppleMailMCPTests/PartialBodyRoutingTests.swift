import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

/// #274 — routing contract for the partial-`.emlx` fallback: `get_email`
/// falls through to AppleScript (the download nudge) exactly when the fast
/// path parsed a partial file AND the requested body is absent. The decision
/// is a pure static helper so the contract is pinned here without live Mail.
final class PartialBodyRoutingTests: XCTestCase {

    private func content(
        partial: Bool, text: String? = nil, html: String? = nil, source: Data? = nil
    ) -> EmailContent {
        EmailContent(
            subject: "s", sender: "a@x.co", toRecipients: [], ccRecipients: [],
            date: "", messageId: "", inReplyTo: "",
            textBody: text, htmlBody: html, rawSource: source,
            fromPartialEmlx: partial
        )
    }

    func testFullFile_neverRoutesToFallback() {
        for fmt in ["text", "html", "source"] {
            XCTAssertFalse(
                CheAppleMailMCPServer.partialBodyNotDownloaded(
                    content: content(partial: false), format: fmt),
                "a non-partial file must never trigger the #274 fallback (format \(fmt))"
            )
        }
    }

    func testPartial_textFormat_routesOnlyWhenTextEmpty() {
        XCTAssertTrue(CheAppleMailMCPServer.partialBodyNotDownloaded(
            content: content(partial: true, text: nil), format: "text"))
        XCTAssertTrue(CheAppleMailMCPServer.partialBodyNotDownloaded(
            content: content(partial: true, text: ""), format: "text"))
        XCTAssertFalse(CheAppleMailMCPServer.partialBodyNotDownloaded(
            content: content(partial: true, text: "hello"), format: "text"))
    }

    func testPartial_sourceFormat_alwaysRoutes() {
        // A partial file's source is header-only by definition — incomplete
        // for a caller who asked for the full RFC 822, even though the
        // header-only rawSource is non-empty.
        XCTAssertTrue(CheAppleMailMCPServer.partialBodyNotDownloaded(
            content: content(partial: true, source: Data("From: a@x.co\r\n".utf8)),
            format: "source"))
    }

    // MARK: - fallback annotation (#274 verify R1, Codex)

    func testFallbackStillMissing_source_headerOnlyIsMissing() {
        // A header-only source is NON-empty yet body-less — the bare isEmpty
        // check silently skipped the annotation here (Codex R1 blocking).
        XCTAssertTrue(CheAppleMailMCPServer.fallbackBodyStillMissing(
            "From: a@x.co\r\nSubject: s\r\n", format: "source"))
        // Separator present but nothing (or only whitespace) after it.
        XCTAssertTrue(CheAppleMailMCPServer.fallbackBodyStillMissing(
            "From: a@x.co\r\nSubject: s\r\n\r\n", format: "source"))
        XCTAssertTrue(CheAppleMailMCPServer.fallbackBodyStillMissing(
            "From: a@x.co\n\n   \n", format: "source"))
        XCTAssertTrue(CheAppleMailMCPServer.fallbackBodyStillMissing("", format: "source"))
    }

    func testFallbackStillMissing_source_withBodyIsComplete() {
        XCTAssertFalse(CheAppleMailMCPServer.fallbackBodyStillMissing(
            "From: a@x.co\r\nSubject: s\r\n\r\nhello body", format: "source"))
        XCTAssertFalse(CheAppleMailMCPServer.fallbackBodyStillMissing(
            "From: a@x.co\n\nbody", format: "source"))
    }

    func testFallbackStillMissing_source_mixedNewlines_usesEarliestSeparator() {
        // #274 verify R2 (Codex): LF top-level separator + a trailing
        // CRLF-CRLF at the END of the body — the CRLF-preferring lookup
        // matched the late pair, saw nothing after it, and wrongly flagged a
        // message that HAS a body. The earliest separator must win.
        XCTAssertFalse(CheAppleMailMCPServer.fallbackBodyStillMissing(
            "From: a@x.co\nSubject: s\n\nhello\r\n\r\n", format: "source"))
        // Symmetric shape: CRLF headers first — earliest is the CRLF pair.
        XCTAssertFalse(CheAppleMailMCPServer.fallbackBodyStillMissing(
            "From: a@x.co\r\n\r\nbody\n\n", format: "source"))
    }

    func testFallbackStillMissing_bodyFormats_useEmptiness() {
        for fmt in ["text", "html"] {
            XCTAssertTrue(CheAppleMailMCPServer.fallbackBodyStillMissing("", format: fmt))
            XCTAssertFalse(CheAppleMailMCPServer.fallbackBodyStillMissing("x", format: fmt))
        }
    }

    func testPartial_htmlFormat_routesWhenBothBodiesAbsent() {
        XCTAssertTrue(CheAppleMailMCPServer.partialBodyNotDownloaded(
            content: content(partial: true), format: "html"))
        XCTAssertFalse(CheAppleMailMCPServer.partialBodyNotDownloaded(
            content: content(partial: true, html: "<p>x</p>"), format: "html"))
        // A text-only body still counts as a body for the html format (the
        // handler returns whichever bodies parsed).
        XCTAssertFalse(CheAppleMailMCPServer.partialBodyNotDownloaded(
            content: content(partial: true, text: "x"), format: "html"))
    }
}
