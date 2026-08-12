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

/// #358 — `mailboxName` carried #344's `%2F` defect: it took the substring
/// after the last `/` of the LOSSY decoded path, so a mailbox whose NAME
/// contains a slash reported the wrong leaf. It had zero consumers at the time,
/// so nothing was broken yet — it was fixed rather than deleted precisely
/// because it would have handed its first user a wrong answer.
final class MailboxNameLeafTests: XCTestCase {

    func testLiteralSlashInName_isNotSplit() {
        let u = MailboxURL.decode("imap://UUID/R%26D%2FSent")
        XCTAssertEqual(u?.mailboxName, "R&D/Sent",
            "the whole name IS the leaf — %2F is part of it, not a separator")
    }

    func testGenuineHierarchy_stillYieldsTheLeaf() {
        XCTAssertEqual(MailboxURL.decode("imap://UUID/R%26D/Sent")?.mailboxName, "Sent")
        XCTAssertEqual(MailboxURL.decode("imap://UUID/%5BGmail%5D/%E5%AF%84%E4%BB%B6%E5%82%99%E4%BB%BD")?.mailboxName,
                       "寄件備份", "bracketed + CJK nesting still resolves its leaf")
    }

    func testTopLevel_isItsOwnLeaf() {
        XCTAssertEqual(MailboxURL.decode("imap://UUID/INBOX")?.mailboxName, "INBOX")
    }

    /// The two URLs share one `mailboxPath` but differ in components — which is
    /// the whole reason the leaf must come from components.
    func testTheTwoFormsDisagreeOnLeafDespiteEqualMailboxPath() {
        let named = MailboxURL.decode("imap://UUID/R%26D%2FSent")
        let nested = MailboxURL.decode("imap://UUID/R%26D/Sent")
        XCTAssertEqual(named?.mailboxPath, nested?.mailboxPath, "lossy paths are identical")
        XCTAssertNotEqual(named?.mailboxName, nested?.mailboxName, "…but the leaves are not")
    }
}
