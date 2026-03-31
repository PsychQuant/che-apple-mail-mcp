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
        let raw = "From: =?utf-8?Q?=E9=84=AD=E6=BE=88?= <kiki830621@gmail.com>\r\n\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        let fromValue = headers["from"] ?? ""
        XCTAssertTrue(fromValue.contains("鄭澈"), "Expected '鄭澈' in '\(fromValue)'")
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
