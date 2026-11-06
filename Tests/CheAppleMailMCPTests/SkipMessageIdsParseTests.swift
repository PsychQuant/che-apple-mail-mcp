import XCTest
@testable import MailSQLite
@testable import CheAppleMailMCP

/// #177: `parseSkipMessageIds` must handle any line ending. The CRLF case is the
/// regression the 6-AI verify caught — a `\r\n` file is a single grapheme, so a
/// bare `split("\n")` returned the whole file as one bogus entry and dedup
/// silently no-op'd (re-archiving everything).
final class SkipMessageIdsParseTests: XCTestCase {

    func testLF() {
        XCTAssertEqual(CheAppleMailMCPServer.parseSkipMessageIds("<a@x>\n<b@x>\n"),
                       ["<a@x>", "<b@x>"])
    }

    func testCRLF_regression() {
        // Would have been a single bogus entry before the fix.
        XCTAssertEqual(CheAppleMailMCPServer.parseSkipMessageIds("<a@x>\r\n<b@x>\r\n"),
                       ["<a@x>", "<b@x>"])
    }

    func testLoneCR() {
        XCTAssertEqual(CheAppleMailMCPServer.parseSkipMessageIds("<a@x>\r<b@x>"),
                       ["<a@x>", "<b@x>"])
    }

    func testBlankLinesAndCommentsIgnored() {
        XCTAssertEqual(
            CheAppleMailMCPServer.parseSkipMessageIds("<a@x>\n\n  # a comment\n<b@x>\n#another"),
            ["<a@x>", "<b@x>"])
    }

    func testSurroundingWhitespaceTrimmed() {
        XCTAssertEqual(CheAppleMailMCPServer.parseSkipMessageIds("  <a@x>  \r\n\t<b@x>\t"),
                       ["<a@x>", "<b@x>"])
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertTrue(CheAppleMailMCPServer.parseSkipMessageIds("").isEmpty)
        XCTAssertTrue(CheAppleMailMCPServer.parseSkipMessageIds("\n\n   \r\n").isEmpty)
    }

    // MARK: - #613: only CR and LF end a line

    /// `RFC822Parser` keeps these characters inside a value since #555, so a
    /// stored Message-ID can hold them and the skip file must not split it.
    func testUnicodeLineCharactersStayInsideAnEntry() {
        for scalar in ["\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let id = "<a\(scalar)b@x>"
            XCTAssertEqual(CheAppleMailMCPServer.parseSkipMessageIds("\(id)\n<c@x>\n"), [id, "<c@x>"])
        }
    }

    func testAnEntryMatchesWhatTheHeaderParserStores() {
        let stored = RFC822Parser.parseHeaders(from: Data("Message-ID: <a\u{2028}b@x>\r\n\r\n".utf8))["message-id"]
        XCTAssertEqual(stored, "<a\u{2028}b@x>")
        XCTAssertEqual(CheAppleMailMCPServer.parseSkipMessageIds("# archive\r\n\(stored ?? "")\r\n"), [stored ?? ""])
    }

    func testUnicodeLineCharactersAtTheEndsOfAnEntryAreKept() {
        XCTAssertEqual(CheAppleMailMCPServer.parseSkipMessageIds("\u{2028}<a@x>\u{0085}\n"), ["\u{2028}<a@x>\u{0085}"])
    }

    func testBareCarriageReturnStillEndsALine() {
        XCTAssertEqual(CheAppleMailMCPServer.parseSkipMessageIds("<a@x>\r<b@x>\r\n<c@x>"), ["<a@x>", "<b@x>", "<c@x>"])
    }
}
