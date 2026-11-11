import SQLite3
import XCTest
@testable import MailSQLite

final class FilesystemQueryTests: XCTestCase {

    // MARK: - Helpers

    private func makeReader() throws -> EnvelopeIndexReader {
        let path = try realEnvelopeIndexPathOrSkip()
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

    /// #656: a reader over a throwaway index (it only needs a file SQLite can read), with the
    /// account mapping injected so it reads no AccountsMap.plist either.
    private func readerWithVIPList(at vipPath: String?) throws -> EnvelopeIndexReader {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vip656-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_open(index, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY)", nil, nil, nil), SQLITE_OK)
        return try EnvelopeIndexReader(databasePath: index, accountMapping: [:], vipMailboxesPath: vipPath)
    }

    // spec-example: sqlite-query-engine / an injected VIP list is the one listed
    func testAnInjectedVIPListIsTheOneListed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vip656-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("VIPMailboxes.plist")
        try PropertyListSerialization.data(fromPropertyList: [["address": "vip@example.invalid"]], format: .xml, options: 0)
            .write(to: plist)

        let listed = try readerWithVIPList(at: plist.path).listVIPSenders()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["address"] as? String, "vip@example.invalid")

        let missing = try readerWithVIPList(at: dir.appendingPathComponent("absent.plist").path).listVIPSenders()
        XCTAssertTrue(missing.isEmpty, "\(missing)")
    }

    // spec-example: sqlite-query-engine / without an injected path the user's VIP list is read
    func testWithoutAnInjectedPathTheUsersVIPListIsRead() {
        let original = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = nil
        defer { EnvelopeIndexReader.mailStoragePathOverride = original }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(EnvelopeIndexReader.defaultVIPMailboxesPath, "\(home)/Library/Mail/V10/MailData/VIPMailboxes.plist")
    }

    // spec-example: sqlite-query-engine / the default follows the test override of the mail storage path
    /// #656 verify: the branch production uses (no VIP list path) reads under the mail storage
    /// path. The override keeps the test off the user's own VIP list.
    func testTheDefaultFollowsTheMailStorageOverride() throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("vip656-storage-\(UUID().uuidString)")
        let mailData = storage.appendingPathComponent("MailData")
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        try PropertyListSerialization.data(fromPropertyList: [["address": "override@example.invalid"]], format: .xml, options: 0)
            .write(to: mailData.appendingPathComponent("VIPMailboxes.plist"))
        let original = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = storage.path
        defer { EnvelopeIndexReader.mailStoragePathOverride = original }

        let listed = try readerWithVIPList(at: nil).listVIPSenders()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["address"] as? String, "override@example.invalid")
    }
}
