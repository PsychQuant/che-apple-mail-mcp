import XCTest
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
}
