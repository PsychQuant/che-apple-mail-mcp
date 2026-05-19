import XCTest
@testable import MailSQLite

final class HeaderParserTests: XCTestCase {

    // MARK: - Basic header parsing

    func testParseSimpleHeaders() {
        let raw = "From: alice@example.com\r\nTo: bob@example.com\r\nSubject: Hello\r\n\r\nBody"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        XCTAssertEqual(headers["from"], "alice@example.com")
        XCTAssertEqual(headers["to"], "bob@example.com")
        XCTAssertEqual(headers["subject"], "Hello")
    }

    // MARK: - Header folding

    func testFoldedHeader() {
        let raw = "Subject: This is a very long\r\n subject that spans multiple lines\r\n\r\nBody"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        XCTAssertEqual(headers["subject"], "This is a very long subject that spans multiple lines")
    }

    func testFoldedHeaderWithTab() {
        let raw = "Subject: First part\r\n\tsecond part\r\n\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        XCTAssertEqual(headers["subject"], "First part second part")
    }

    // MARK: - RFC 2047 encoded-word

    func testDecodeBase64UTF8() {
        let raw = "Subject: =?utf-8?B?5pel5pys6Kqe?=\r\n\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        XCTAssertEqual(headers["subject"], "日本語")
    }

    func testDecodeQuotedPrintable() {
        let raw = "From: =?utf-8?Q?=E6=B8=AC=E8=A9=A6?= <alice@example.com>\r\n\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        let fromValue = headers["from"] ?? ""
        XCTAssertTrue(fromValue.contains("測試"), "Expected '測試' in '\(fromValue)'")
    }

    func testDecodeMultipleEncodedWords() {
        let raw = "Subject: =?utf-8?B?5pel?= =?utf-8?B?5pys?=\r\n\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        XCTAssertEqual(headers["subject"], "日本")
    }

    func testMixedEncodedAndPlainText() {
        let raw = "Subject: Re: =?utf-8?B?5pel5pys6Kqe?= message\r\n\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        XCTAssertEqual(headers["subject"], "Re: 日本語 message")
    }

    // MARK: - Content-Type parsing

    func testParseContentType() {
        let headers = RFC822Parser.parseHeaders(from: Data("Content-Type: text/html; charset=utf-8\r\n\r\n".utf8))
        XCTAssertEqual(headers["content-type"], "text/html; charset=utf-8")
    }

    // MARK: - Structured headers left raw (#115)

    func testContentDispositionWithEncodedWordParamsLeftRaw() {
        // #115: Content-Disposition is a structured MIME header. parseHeaders
        // must NOT RFC 2047-decode it at the raw-header level — encoded-words
        // inside filename params belong to the parameter layer and are decoded
        // per-parameter by MIMEParser.resolveFilename. A header-level scan
        // decodes encoded-words fully contained in one RFC 2231 continuation
        // segment but mangles ones whose `=?` straddles the `"; filename*N="`
        // boundary, leaving a half-decoded value resolveFilename cannot
        // recognise. The fixture mirrors a real Yahoo Mail email: the second
        // encoded-word's opener is split — `=` ends filename*0, `?UTF-8…`
        // starts filename*1.
        let raw = "Content-Disposition: ATTACHMENT;\r\n"
            + "\tfilename*0=\"=?UTF-8?Q?=E6=B8=AC=E8=A9=A6?= =\";\r\n"
            + "\tfilename*1=\"?UTF-8?Q?=E9=99=84=E4=BB=B6.pdf?=\"\r\n\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        let cd = headers["content-disposition"] ?? ""
        XCTAssertTrue(cd.contains("=?UTF-8?Q?=E6=B8=AC=E8=A9=A6?="),
                      "Content-Disposition must be left RAW — the encoded-word must "
                      + "survive intact for per-parameter decoding; got: \(cd)")
        XCTAssertFalse(cd.contains("測試"),
                       "raw-header-level RFC 2047 decode must NOT run on Content-Disposition "
                       + "(it mangles encoded-words split across RFC 2231 continuation); got: \(cd)")
    }

    func testDecodeRFC2047_dropsCRLFBetweenConsecutiveEncodedWords() {
        // #125: pre-fix the inter-encoded-word whitespace-skip in
        // `decodeRFC2047` only stripped ` ` / `\t`, so a CR/LF between two
        // encoded-words leaked through as a literal control character into
        // the decoded result — RFC 2047 §6.2 says "linear-white-space"
        // (RFC 822 LWS = space + tab + CRLF) between encoded-words is
        // folded, so all four whitespace characters must be skipped.
        let lf = "=?utf-8?B?YWJj?=\n=?utf-8?B?ZGVm?="
        let cr = "=?utf-8?B?YWJj?=\r=?utf-8?B?ZGVm?="
        let crlf = "=?utf-8?B?YWJj?=\r\n=?utf-8?B?ZGVm?="
        let space = "=?utf-8?B?YWJj?= =?utf-8?B?ZGVm?="
        let tab = "=?utf-8?B?YWJj?=\t=?utf-8?B?ZGVm?="
        for (input, label) in [(lf, "LF"), (cr, "CR"), (crlf, "CRLF"), (space, "space"), (tab, "tab")] {
            XCTAssertEqual(RFC822Parser.decodeRFC2047(input), "abcdef",
                           "consecutive encoded-words separated by \(label) must concatenate cleanly")
        }
    }

    func testSubjectStillRFC2047DecodedAfterStructuredHeaderSkip() {
        // Guard: skipping decode for content-* headers must not regress the
        // legitimate decode of display headers like Subject.
        let raw = "Content-Type: text/plain\r\nSubject: =?utf-8?B?5pel5pys6Kqe?=\r\n\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        XCTAssertEqual(headers["subject"], "日本語")
        XCTAssertEqual(headers["content-type"], "text/plain")
    }

    // MARK: - Header body split

    func testExtractBody() {
        let raw = "Subject: Test\r\n\r\nThis is the body"
        let data = Data(raw.utf8)
        let bodyOffset = RFC822Parser.headerBodySplitOffset(in: data)
        XCTAssertNotNil(bodyOffset)
        if let offset = bodyOffset {
            let body = String(data: data[offset...], encoding: .utf8)
            XCTAssertEqual(body, "This is the body")
        }
    }
}
