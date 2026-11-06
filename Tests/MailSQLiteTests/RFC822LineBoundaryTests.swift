import XCTest
@testable import MailSQLite

/// #555: a header block ends a line only at CR or LF (RFC 5322 §2.2). The
/// parser used to split with `CharacterSet.newlines`, which also contains
/// U+000B, U+000C, U+0085, U+2028 and U+2029, so any of those inside a header
/// value cut the value short — and a tail shaped like `Name: value` became a
/// second header the sender had forged.
final class RFC822LineBoundaryTests: XCTestCase {

    private func headers(_ raw: String) -> [String: String] {
        RFC822Parser.parseHeaders(from: Data(raw.utf8))
    }

    // MARK: - The seven rows of the issue's evidence table

    func testLineSeparatorInSubjectIsKeptInTheValue() {
        XCTAssertEqual(headers("Subject: a\u{2028}b\r\n\r\n")["subject"], "a\u{2028}b")
    }

    func testLineSeparatorInMessageIDIsKeptInTheValue() {
        XCTAssertEqual(headers("Message-ID: <a\u{2028}b@x>\r\n\r\n")["message-id"], "<a\u{2028}b@x>")
    }

    func testVerticalTabInMessageIDIsKeptInTheValue() {
        XCTAssertEqual(headers("Message-ID: <a\u{000B}b@x>\r\n\r\n")["message-id"], "<a\u{000B}b@x>")
    }

    func testNextLineInMessageIDIsKeptInTheValue() {
        XCTAssertEqual(headers("Message-ID: <a\u{0085}b@x>\r\n\r\n")["message-id"], "<a\u{0085}b@x>")
    }

    func testForgedMessageIDAfterARealOneDoesNotOverwriteIt() {
        let h = headers("Message-ID: <real@x>\r\nSubject: hi\u{2028}Message-ID: <forged@x>\r\n\r\n")
        XCTAssertEqual(h["message-id"], "<real@x>")
        XCTAssertEqual(h["subject"], "hi\u{2028}Message-ID: <forged@x>")
    }

    func testForgedMessageIDWithoutARealOneIsNotCreated() {
        let h = headers("Subject: hi\u{2028}Message-ID: <forged@x>\r\n\r\n")
        XCTAssertNil(h["message-id"])
        XCTAssertEqual(h["subject"], "hi\u{2028}Message-ID: <forged@x>")
    }

    func testRealMessageIDAfterAForgedOneIsKept() {
        let h = headers("Subject: hi\u{2028}Message-ID: <forged@x>\r\nMessage-ID: <real@x>\r\n\r\n")
        XCTAssertEqual(h["message-id"], "<real@x>")
    }

    // MARK: - The other Unicode line characters

    func testFormFeedAndParagraphSeparatorAreKeptInTheValue() {
        let h = headers("Subject: a\u{000C}b\r\nFrom: c\u{2029}Date: forged\r\n\r\n")
        XCTAssertEqual(h["subject"], "a\u{000C}b")
        XCTAssertEqual(h["from"], "c\u{2029}Date: forged")
        XCTAssertNil(h["date"])
    }

    // MARK: - Real line endings still split

    func testCRLFBlockSplitsEveryLine() {
        let h = headers("From: a@x\r\nTo: b@x\r\nSubject: hi\r\n\r\nbody")
        XCTAssertEqual(h["from"], "a@x")
        XCTAssertEqual(h["to"], "b@x")
        XCTAssertEqual(h["subject"], "hi")
    }

    func testLFOnlyBlockSplitsEveryLine() {
        let h = headers("From: a@x\nTo: b@x\nSubject: hi\n\nbody")
        XCTAssertEqual(h["from"], "a@x")
        XCTAssertEqual(h["to"], "b@x")
        XCTAssertEqual(h["subject"], "hi")
    }

    func testBareCRStillEndsALine() {
        let h = headers("From: a@x\rSubject: hi")
        XCTAssertEqual(h["from"], "a@x")
        XCTAssertEqual(h["subject"], "hi")
    }

    func testFoldedValuesAreStillJoined() {
        XCTAssertEqual(headers("Subject: a\r\n b\r\n\r\n")["subject"], "a b")
        XCTAssertEqual(headers("Subject: a\n\tb\n\n")["subject"], "a b")
    }

    // MARK: - MIME part headers go through the same parser

    func testForgedContentTypeInAPartHeaderIsNotApplied() {
        let body = "--B\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "X-Note: a\u{2028}Content-Type: text/html\r\n"
            + "\r\n"
            + "hello\r\n"
            + "--B--\r\n"
        let result = MIMEParser.parseBody(
            Data(body.utf8),
            headers: ["content-type": "multipart/mixed; boundary=\"B\""]
        )
        XCTAssertEqual(result.textBody?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertNil(result.htmlBody)
    }
}
