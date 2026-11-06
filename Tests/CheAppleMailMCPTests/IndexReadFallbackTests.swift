import XCTest
@testable import CheAppleMailMCP
import MailSQLite

/// #549 — read tools that used to let an index error propagate now fall back
/// to AppleScript, but only for errors that mean "the index could not finish
/// this read". Resolution answers stay answers: falling back on them would hand
/// AppleScript the same unresolvable name and turn a diagnostic into a silent
/// zero (#202, #344).
final class IndexReadFallbackTests: XCTestCase {

    func testQueryFailuresFallBack() {
        XCTAssertTrue(CheAppleMailMCPServer.isIndexReadFailure(
            MailSQLiteError.queryFailed("Search stopped before the end of its results: database disk image is malformed (SQLite result code 11)")))
        XCTAssertTrue(CheAppleMailMCPServer.isIndexReadFailure(MailSQLiteError.queryFailed("Database not open")))
    }

    func testResolutionAnswersDoNotFallBack() {
        XCTAssertFalse(CheAppleMailMCPServer.isIndexReadFailure(MailSQLiteError.accountNotResolvable(name: "nobody@example.com")))
        XCTAssertFalse(CheAppleMailMCPServer.isIndexReadFailure(
            MailSQLiteError.mailboxNotResolvable(name: "inbox2", candidates: ["INBOX"])))
        XCTAssertFalse(CheAppleMailMCPServer.isIndexReadFailure(MailError.invalidParameter("x")))
    }
}
