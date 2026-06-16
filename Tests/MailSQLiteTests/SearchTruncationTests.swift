import XCTest
import SQLite3
@testable import MailSQLite

/// Deterministic truncation-signal tests (#204) using a hermetic temp SQLite
/// fixture — independent of whether the host has a real Apple Mail Envelope
/// Index, so they run in CI / non-FDA shells.
final class SearchTruncationTests: XCTestCase {

    /// Build a temp "Envelope Index" with `count` non-deleted messages whose
    /// subject all contain "match", one sender, one mailbox (INBOX of UUID-A).
    /// Returns the DB path; teardown removes it.
    private func makeFixtureDB(messageCount count: Int) throws -> String {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "SearchTruncationTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            throw NSError(domain: "SearchTruncationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "open failed at \(dbPath)"])
        }
        defer { sqlite3_close(db) }

        var sql = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, unread_count INTEGER DEFAULT 0);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER, date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        INSERT INTO addresses (ROWID, address, comment) VALUES (1, 'sender@example.com', 'Sender');
        INSERT INTO mailboxes (ROWID, url, unread_count) VALUES (1, 'imap://UUID-A/INBOX', 0);
        """
        for i in 1...max(count, 1) where count > 0 {
            sql += "INSERT INTO subjects (ROWID, subject) VALUES (\(i), 'match topic \(i)');\n"
            sql += "INSERT INTO messages (ROWID, subject, sender, mailbox, date_received, deleted) VALUES (\(i), \(i), 1, 1, \(1000 + i), 0);\n"
        }

        var errMsg: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let m = errMsg.map { String(cString: $0) } ?? "unknown"
            throw NSError(domain: "SearchTruncationTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "exec failed: \(m)"])
        }
        return dbPath
    }

    private func makeReader(messageCount: Int) throws -> EnvelopeIndexReader {
        try EnvelopeIndexReader(
            databasePath: try makeFixtureDB(messageCount: messageCount),
            accountMapping: ["UUID-A": "Alice"])
    }

    // MARK: - searchPage

    func testSearchPage_truncatedWhenMoreThanLimit() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.searchPage(SearchParameters(query: "match", field: .subject, limit: 3))
        XCTAssertEqual(page.results.count, 3, "returns at most limit")
        XCTAssertTrue(page.truncated, "5 matches at limit 3 must report truncated")
    }

    func testSearchPage_notTruncatedAtExactLimit() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.searchPage(SearchParameters(query: "match", field: .subject, limit: 5))
        XCTAssertEqual(page.results.count, 5)
        XCTAssertFalse(page.truncated, "exactly limit matches must NOT be truncated (limit+1 fetch)")
    }

    func testSearchPage_notTruncatedUnderLimit() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.searchPage(SearchParameters(query: "match", field: .subject, limit: 10))
        XCTAssertEqual(page.results.count, 5)
        XCTAssertFalse(page.truncated)
    }

    func testSearchPage_zeroMatchNotTruncated() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.searchPage(SearchParameters(query: "no_such_term_zzqx", field: .subject, limit: 3))
        XCTAssertEqual(page.results.count, 0)
        XCTAssertFalse(page.truncated)
    }

    func testSearch_backwardCompatWrapperMatchesPageResults() throws {
        let reader = try makeReader(messageCount: 5)
        let params = SearchParameters(query: "match", field: .subject, limit: 3)
        XCTAssertEqual(try reader.search(params).count, try reader.searchPage(params).results.count)
    }

    // MARK: - listEmailsPage

    func testListEmailsPage_truncatedWhenMoreThanLimit() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.listEmailsPage(mailbox: "INBOX", accountName: "Alice", limit: 3)
        XCTAssertEqual(page.results.count, 3)
        XCTAssertTrue(page.truncated)
    }

    func testListEmailsPage_notTruncatedUnderLimit() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.listEmailsPage(mailbox: "INBOX", accountName: "Alice", limit: 10)
        XCTAssertEqual(page.results.count, 5)
        XCTAssertFalse(page.truncated)
    }

    func testListEmails_backwardCompatWrapperMatchesPageResults() throws {
        let reader = try makeReader(messageCount: 5)
        XCTAssertEqual(
            try reader.listEmails(mailbox: "INBOX", accountName: "Alice", limit: 3).count,
            try reader.listEmailsPage(mailbox: "INBOX", accountName: "Alice", limit: 3).results.count)
    }

    // MARK: - Limit clamping (#204 verify CRITICAL: negative limit must not trap prefix())

    func testSearchPage_negativeLimitDoesNotTrap() throws {
        let reader = try makeReader(messageCount: 5)
        // Pre-fix: limit -1 → fetchLimit 0 → Array(prefix(-1)) traps (fatal).
        // Post-fix: clamped to 0 → empty, crash-free.
        let page = try reader.searchPage(SearchParameters(query: "match", field: .subject, limit: -1))
        XCTAssertEqual(page.results.count, 0)
    }

    func testListEmailsPage_negativeLimitDoesNotTrap() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.listEmailsPage(mailbox: "INBOX", accountName: "Alice", limit: -1)
        XCTAssertEqual(page.results.count, 0)
    }

    func testSearchPage_zeroLimitNoMatchNotTruncated() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.searchPage(SearchParameters(query: "no_such_zzqx", field: .subject, limit: 0))
        XCTAssertEqual(page.results.count, 0)
        XCTAssertFalse(page.truncated)
    }

    func testSearchPage_zeroLimitWithMatchesIsTruncated() throws {
        let reader = try makeReader(messageCount: 5)
        // limit 0 + matches exist → returns nothing but signals there is more.
        let page = try reader.searchPage(SearchParameters(query: "match", field: .subject, limit: 0))
        XCTAssertEqual(page.results.count, 0)
        XCTAssertTrue(page.truncated)
    }

    func testListEmailsPage_notTruncatedAtExactLimit() throws {
        let reader = try makeReader(messageCount: 5)
        let page = try reader.listEmailsPage(mailbox: "INBOX", accountName: "Alice", limit: 5)
        XCTAssertEqual(page.results.count, 5)
        XCTAssertFalse(page.truncated, "exactly limit must NOT be truncated (limit+1 fetch)")
    }
}
