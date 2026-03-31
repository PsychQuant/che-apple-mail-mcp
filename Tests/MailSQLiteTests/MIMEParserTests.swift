import XCTest
@testable import MailSQLite

final class MIMEParserTests: XCTestCase {

    func testPlainTextBody() {
        let headers = ["content-type": "text/plain; charset=utf-8"]
        let body = Data("Hello, world!".utf8)
        let result = MIMEParser.parseBody(body, headers: headers)
        XCTAssertEqual(result.textBody, "Hello, world!")
        XCTAssertNil(result.htmlBody)
    }

    func testHTMLBody() {
        let headers = ["content-type": "text/html; charset=utf-8"]
        let body = Data("<p>Hello</p>".utf8)
        let result = MIMEParser.parseBody(body, headers: headers)
        XCTAssertNil(result.textBody)
        XCTAssertEqual(result.htmlBody, "<p>Hello</p>")
    }

    func testBase64EncodedBody() {
        let headers = [
            "content-type": "text/plain; charset=utf-8",
            "content-transfer-encoding": "base64"
        ]
        let encoded = Data("SGVsbG8sIHdvcmxkIQ==".utf8) // "Hello, world!"
        let result = MIMEParser.parseBody(encoded, headers: headers)
        XCTAssertEqual(result.textBody, "Hello, world!")
    }

    func testQuotedPrintableBody() {
        let headers = [
            "content-type": "text/plain; charset=utf-8",
            "content-transfer-encoding": "quoted-printable"
        ]
        let qp = Data("Hello=20World".utf8)
        let result = MIMEParser.parseBody(qp, headers: headers)
        XCTAssertEqual(result.textBody, "Hello World")
    }

    func testMultipartAlternative() {
        let boundary = "----=_Part_123"
        let headers = ["content-type": "multipart/alternative; boundary=\"\(boundary)\""]
        let body = """
        ------=_Part_123\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain text version\r
        ------=_Part_123\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML version</p>\r
        ------=_Part_123--\r
        """
        let result = MIMEParser.parseBody(Data(body.utf8), headers: headers)
        XCTAssertEqual(result.textBody, "Plain text version\r\n")
        XCTAssertEqual(result.htmlBody, "<p>HTML version</p>\r\n")
    }

    func testContentTypeParsing() {
        let (mimeType, params) = MIMEParser.parseContentType("text/html; charset=\"utf-8\"; name=test")
        XCTAssertEqual(mimeType, "text/html")
        XCTAssertEqual(params["charset"], "utf-8")
        XCTAssertEqual(params["name"], "test")
    }

    func testDefaultContentType() {
        let headers: [String: String] = [:]
        let body = Data("Hello".utf8)
        let result = MIMEParser.parseBody(body, headers: headers)
        XCTAssertEqual(result.textBody, "Hello")
    }

    func testRealEmlxParsing() throws {
        // Integration test: parse a real .emlx file
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }

        let reader = try EnvelopeIndexReader(databasePath: path)
        let results = try reader.search(SearchParameters(query: "a", limit: 1))
        guard let msg = results.first else {
            throw XCTSkip("No messages found")
        }

        // Try to find and parse the .emlx file
        // We need a mailbox URL from the DB, but search results only have decoded path.
        // Skip if we can't resolve the path.
        throw XCTSkip("Full .emlx integration test requires mailbox URL from DB")
    }
}
