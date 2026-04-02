import XCTest
@testable import MailSQLite

final class FilesystemQueryTests: XCTestCase {

    // MARK: - Helpers

    private func makeReader() throws -> EnvelopeIndexReader {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available at \(path)")
        }
        return try EnvelopeIndexReader(databasePath: path)
    }

    // MARK: - listAccounts

    func testListAccounts() throws {
        let reader = try makeReader()
        let accounts = reader.listAccounts()
        XCTAssertFalse(accounts.isEmpty, "listAccounts should return at least one account")
        for account in accounts {
            XCTAssertNotNil(account["name"], "Account should have 'name' key")
            XCTAssertNotNil(account["uuid"], "Account should have 'uuid' key")
        }
    }

    // MARK: - listMailboxes

    func testListMailboxes() throws {
        let reader = try makeReader()
        let mailboxes = try reader.listMailboxes()
        XCTAssertFalse(mailboxes.isEmpty, "listMailboxes should return at least one mailbox")
        for mailbox in mailboxes {
            XCTAssertNotNil(mailbox["name"], "Mailbox should have 'name' key")
            XCTAssertNotNil(mailbox["account_name"], "Mailbox should have 'account_name' key")
            XCTAssertNotNil(mailbox["total_count"], "Mailbox should have 'total_count' key")
            XCTAssertNotNil(mailbox["unread_count"], "Mailbox should have 'unread_count' key")
        }
    }

    // MARK: - listEmails

    func testListEmails() throws {
        let reader = try makeReader()
        let accounts = reader.listAccounts()
        guard let firstAccount = accounts.first,
              let accountName = firstAccount["name"] as? String else {
            throw XCTSkip("No accounts available to test listEmails")
        }

        let emails = try reader.listEmails(mailbox: "INBOX", accountName: accountName, limit: 5)
        // INBOX may be empty for some accounts; just verify structure if non-empty
        for email in emails {
            XCTAssertNotNil(email["id"], "Email should have 'id' key")
            XCTAssertNotNil(email["subject"], "Email should have 'subject' key")
            XCTAssertNotNil(email["sender"], "Email should have 'sender' key")
        }
    }

    // MARK: - getUnreadCount

    func testGetUnreadCount() throws {
        let reader = try makeReader()
        let count = try reader.getUnreadCount()
        XCTAssertGreaterThanOrEqual(count, 0, "Unread count should be non-negative")
    }

    // MARK: - listAttachments

    func testListAttachments() throws {
        let reader = try makeReader()
        let searchParams = SearchParameters(query: "a", limit: 1)
        let results = try reader.search(searchParams)
        guard let firstResult = results.first else {
            throw XCTSkip("No messages found to test listAttachments")
        }

        let attachments = try reader.listAttachments(messageId: firstResult.id)
        // Attachments may be empty; just verify it returns an array without throwing
        _ = attachments // successfully returned without error
    }

    // MARK: - getEmailMetadata

    func testGetEmailMetadata() throws {
        let reader = try makeReader()
        let searchParams = SearchParameters(query: "a", limit: 1)
        let results = try reader.search(searchParams)
        guard let firstResult = results.first else {
            throw XCTSkip("No messages found to test getEmailMetadata")
        }

        let metadata = try reader.getEmailMetadata(messageId: firstResult.id)
        XCTAssertNotNil(metadata["read"], "Metadata should have 'read' key")
        XCTAssertNotNil(metadata["flagged"], "Metadata should have 'flagged' key")
        XCTAssertNotNil(metadata["subject"], "Metadata should have 'subject' key")
    }

    // MARK: - listVIPSenders

    func testListVIPSenders() throws {
        let reader = try makeReader()
        let vips = reader.listVIPSenders()
        // VIP list may be empty; just verify it returns an array without crashing
        _ = vips // successfully returned without error
    }
}
