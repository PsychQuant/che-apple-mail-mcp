import XCTest
@testable import MailSQLite

final class MailboxURLTests: XCTestCase {

    func testDecodeImapURL() {
        let url = "imap://E51B96AC-9499-4FCC-9638-18F2A300EBFE/%5BGmail%5D/%E5%85%A8%E9%83%A8%E9%83%B5%E4%BB%B6"
        let result = MailboxURL.decode(url)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.accountUUID, "E51B96AC-9499-4FCC-9638-18F2A300EBFE")
        XCTAssertEqual(result?.mailboxPath, "[Gmail]/全部郵件")
    }

    func testDecodeEwsURL() {
        let url = "ews://ABCE3A85-06BE-43BC-9B84-2CA6F325612F/%E6%94%B6%E4%BB%B6%E5%8C%A3"
        let result = MailboxURL.decode(url)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.accountUUID, "ABCE3A85-06BE-43BC-9B84-2CA6F325612F")
        XCTAssertEqual(result?.mailboxPath, "收件匣")
    }

    func testDecodeNestedMailboxPath() {
        let url = "imap://UUID-HERE/Work/Projects/Active"
        let result = MailboxURL.decode(url)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.mailboxPath, "Work/Projects/Active")
    }

    func testDecodeInvalidURL() {
        let result = MailboxURL.decode("not-a-valid-url")
        XCTAssertNil(result)
    }

    func testMailboxDisplayName() {
        // Gmail mailboxes under [Gmail]/ should keep the full path
        let url = "imap://UUID/%5BGmail%5D/Sent%20Mail"
        let result = MailboxURL.decode(url)
        XCTAssertEqual(result?.mailboxPath, "[Gmail]/Sent Mail")
    }

    func testDecodeTopLevelMailbox() {
        let url = "imap://UUID/INBOX"
        let result = MailboxURL.decode(url)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.accountUUID, "UUID")
        XCTAssertEqual(result?.mailboxPath, "INBOX")
    }
}
