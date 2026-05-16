import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

/// Tests for `CheAppleMailMCPServer.formatSearchResultForJSON` — the JSON
/// formatter for the `search_emails` tool response.
///
/// Verify-101 caught a P1 integration gap: README + CHANGELOG + `save_attachment`
/// tool description all advertise "Discoverable from search_emails results",
/// but the formatter silently dropped `account_id` from the JSON output. These
/// tests pin the contract so future regression breaks the build.
final class SearchEmailsJsonFormatTests: XCTestCase {

    // MARK: - account_id inclusion contract

    func testFormat_includesAccountId_whenSearchResultHasNonEmptyUUID() {
        let r = SearchResult(
            id: 42,
            subject: "test",
            senderAddress: "alice@example.com",
            senderName: "Alice",
            dateReceived: Date(timeIntervalSince1970: 1700000000),
            accountName: "alice@example.com",
            accountId: "C38E0583-47F8-4468-BE70-43155C15549D",
            mailboxPath: "INBOX",
            isRead: false,
            isFlagged: false,
            toRecipients: ["bob@example.com"]
        )
        let dict = CheAppleMailMCPServer.formatSearchResultForJSON(r)
        XCTAssertEqual(
            dict["account_id"] as? String,
            "C38E0583-47F8-4468-BE70-43155C15549D",
            "search_emails JSON MUST include account_id key when SearchResult has a non-empty UUID. "
            + "This is the documented discovery path for #101 disambiguation — README and "
            + "save_attachment tool description both promise it."
        )
    }

    func testFormat_omitsAccountId_whenSearchResultAccountIdIsNil() {
        let r = SearchResult(
            id: 1, subject: "s", senderAddress: "a@b", senderName: "A",
            dateReceived: Date(timeIntervalSince1970: 0),
            accountName: "Alice",
            accountId: nil,
            mailboxPath: "INBOX",
            isRead: false, isFlagged: false, toRecipients: []
        )
        let dict = CheAppleMailMCPServer.formatSearchResultForJSON(r)
        XCTAssertNil(
            dict["account_id"],
            "When accountId is nil (e.g., corrupted MailboxURL decode upstream), the "
            + "account_id key MUST be omitted from JSON — not present as JSON-null. "
            + "Callers detect presence via `if 'account_id' in result`."
        )
    }

    func testFormat_omitsAccountId_whenSearchResultAccountIdIsEmptyString() {
        let r = SearchResult(
            id: 1, subject: "s", senderAddress: "a@b", senderName: "A",
            dateReceived: Date(timeIntervalSince1970: 0),
            accountName: "Alice",
            accountId: "",
            mailboxPath: "INBOX",
            isRead: false, isFlagged: false, toRecipients: []
        )
        let dict = CheAppleMailMCPServer.formatSearchResultForJSON(r)
        XCTAssertNil(
            dict["account_id"],
            "Empty-string accountId MUST be treated the same as nil — defensive against "
            + "future SearchResult constructions that default to empty string instead of nil."
        )
    }

    // MARK: - Other fields unchanged (regression-lock against accidental omission)

    func testFormat_preservesAllOriginalFields() {
        let r = SearchResult(
            id: 42,
            subject: "Hello",
            senderAddress: "alice@example.com",
            senderName: "Alice",
            dateReceived: Date(timeIntervalSince1970: 1700000000),
            accountName: "Alice's Gmail",
            accountId: "UUID-A",
            mailboxPath: "[Gmail]/INBOX",
            isRead: true,
            isFlagged: false,
            toRecipients: ["bob@example.com", "charlie@example.com"]
        )
        let dict = CheAppleMailMCPServer.formatSearchResultForJSON(r)

        XCTAssertEqual(dict["id"] as? String, "42")
        XCTAssertEqual(dict["subject"] as? String, "Hello")
        XCTAssertEqual(dict["sender"] as? String, "Alice <alice@example.com>")
        XCTAssertEqual(dict["account_name"] as? String, "Alice's Gmail")
        XCTAssertEqual(dict["mailbox"] as? String, "[Gmail]/INBOX")
        XCTAssertEqual(dict["to"] as? [String], ["bob@example.com", "charlie@example.com"])
        // date_received is ISO 8601 formatted — check format prefix
        XCTAssertTrue(
            (dict["date_received"] as? String)?.hasPrefix("2023") ?? false,
            "date_received should be ISO 8601 formatted from 2023 epoch"
        )
    }

    func testFormat_senderFallback_usesSenderNameWhenAddressEmpty() {
        let r = SearchResult(
            id: 1, subject: "s",
            senderAddress: "",
            senderName: "Display Only Sender",
            dateReceived: Date(timeIntervalSince1970: 0),
            accountName: "A", accountId: "UUID",
            mailboxPath: "M",
            isRead: false, isFlagged: false, toRecipients: []
        )
        let dict = CheAppleMailMCPServer.formatSearchResultForJSON(r)
        XCTAssertEqual(
            dict["sender"] as? String, "Display Only Sender",
            "When senderAddress is empty, sender field falls back to senderName "
            + "(without the angle-bracket address suffix)."
        )
    }
}
