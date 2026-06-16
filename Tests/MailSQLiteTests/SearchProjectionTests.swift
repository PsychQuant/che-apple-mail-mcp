import XCTest
import SQLite3
@testable import MailSQLite

/// Tests for the id-only / count projections + logical dedup (#208), using a
/// hermetic temp SQLite fixture that can place each logical email in multiple
/// mailboxes (the Gmail INBOX/Archive/All-Mail duplication the dedup collapses).
final class SearchProjectionTests: XCTestCase {

    /// Build a temp "Envelope Index" with `logicalCount` distinct emails, each
    /// duplicated across `copiesPerEmail` mailboxes (same subject/sender/date,
    /// distinct ROWID + mailbox). All subjects contain "match"; one sender.
    private func makeFixtureDB(logicalCount: Int, copiesPerEmail: Int) throws -> String {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "SearchProjectionTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            throw NSError(domain: "SearchProjectionTests", code: 1,
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
        """
        let copies = max(copiesPerEmail, 1)
        for c in 1...copies {
            sql += "INSERT INTO mailboxes (ROWID, url, unread_count) VALUES (\(c), 'imap://UUID-A/MBX\(c)', 0);\n"
        }
        var rowId = 0
        for i in 1...max(logicalCount, 1) where logicalCount > 0 {
            sql += "INSERT INTO subjects (ROWID, subject) VALUES (\(i), 'match topic \(i)');\n"
            for c in 1...copies {
                rowId += 1
                // All copies of logical email i share subject i, sender 1, date 1000+i.
                sql += "INSERT INTO messages (ROWID, subject, sender, mailbox, date_received, deleted) VALUES (\(rowId), \(i), 1, \(c), \(1000 + i), 0);\n"
            }
        }

        var errMsg: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let m = errMsg.map { String(cString: $0) } ?? "unknown"
            throw NSError(domain: "SearchProjectionTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "exec failed: \(m)"])
        }
        return dbPath
    }

    private func makeReader(logicalCount: Int, copiesPerEmail: Int = 1) throws -> EnvelopeIndexReader {
        try EnvelopeIndexReader(
            databasePath: try makeFixtureDB(logicalCount: logicalCount, copiesPerEmail: copiesPerEmail),
            accountMapping: ["UUID-A": "Alice"])
    }

    private func params(limit: Int) -> SearchParameters {
        SearchParameters(query: "match", field: .subject, limit: limit)
    }

    // MARK: - searchIds (no dedup)

    func testSearchIds_returnsRowIdsOnly() throws {
        let reader = try makeReader(logicalCount: 3)
        let page = try reader.searchIds(params(limit: 10), dedup: false)
        XCTAssertEqual(page.ids.count, 3)
        XCTAssertFalse(page.truncated)
        // ids are real message ROWIDs (1...3 for 3 emails × 1 copy).
        XCTAssertEqual(Set(page.ids), Set([1, 2, 3]))
    }

    func testSearchIds_noDedupKeepsAllMailboxCopies() throws {
        // 3 logical emails × 3 mailbox copies = 9 raw rows.
        let reader = try makeReader(logicalCount: 3, copiesPerEmail: 3)
        let page = try reader.searchIds(params(limit: 100), dedup: false)
        XCTAssertEqual(page.ids.count, 9, "without dedup every mailbox copy is its own row")
    }

    func testSearchIds_truncatedWhenMoreThanLimit() throws {
        let reader = try makeReader(logicalCount: 5)
        let page = try reader.searchIds(params(limit: 3), dedup: false)
        XCTAssertEqual(page.ids.count, 3, "returns at most limit")
        XCTAssertTrue(page.truncated, "5 matches at limit 3 must report truncated")
    }

    func testSearchIds_notTruncatedAtExactLimit() throws {
        let reader = try makeReader(logicalCount: 5)
        let page = try reader.searchIds(params(limit: 5), dedup: false)
        XCTAssertEqual(page.ids.count, 5)
        XCTAssertFalse(page.truncated, "exactly limit must NOT be truncated (limit+1 fetch)")
    }

    func testSearchIds_negativeLimitDoesNotTrap() throws {
        let reader = try makeReader(logicalCount: 5)
        // Mirrors the #204 prefix() trap guard on the light path.
        let page = try reader.searchIds(params(limit: -1), dedup: false)
        XCTAssertEqual(page.ids.count, 0)
    }

    func testSearchIds_zeroMatch() throws {
        let reader = try makeReader(logicalCount: 5)
        let page = try reader.searchIds(
            SearchParameters(query: "no_such_zzqx", field: .subject, limit: 3), dedup: false)
        XCTAssertEqual(page.ids.count, 0)
        XCTAssertFalse(page.truncated)
    }

    // MARK: - searchIds (logical dedup)

    func testSearchIds_dedupCollapsesMailboxDuplicates() throws {
        // 3 logical emails × 3 mailbox copies. Dedup → one rowId per logical email.
        let reader = try makeReader(logicalCount: 3, copiesPerEmail: 3)
        let page = try reader.searchIds(params(limit: 100), dedup: true)
        XCTAssertEqual(page.ids.count, 3, "dedup collapses 9 raw rows to 3 logical emails")
        XCTAssertFalse(page.truncated)
        // One unique rowId per logical email (no duplicate ids).
        XCTAssertEqual(Set(page.ids).count, 3)
    }

    func testSearchIds_dedupTruncationCountsLogicalEmails() throws {
        // 5 logical × 3 copies = 15 raw rows, but dedup truncation is over groups.
        let reader = try makeReader(logicalCount: 5, copiesPerEmail: 3)
        let page = try reader.searchIds(params(limit: 3), dedup: true)
        XCTAssertEqual(page.ids.count, 3)
        XCTAssertTrue(page.truncated, "5 logical emails at limit 3 (deduped) must be truncated")
    }

    // MARK: - searchCount

    func testSearchCount_ignoresLimit() throws {
        // 5 logical × 3 copies = 15 raw rows; count ignores limit.
        let reader = try makeReader(logicalCount: 5, copiesPerEmail: 3)
        let count = try reader.searchCount(params(limit: 1), dedup: false)
        XCTAssertEqual(count, 15, "count is total matches regardless of limit")
    }

    func testSearchCount_dedupCountsLogicalEmails() throws {
        let reader = try makeReader(logicalCount: 5, copiesPerEmail: 3)
        let count = try reader.searchCount(params(limit: 1), dedup: true)
        XCTAssertEqual(count, 5, "deduped count is the number of logical emails")
    }

    func testSearchCount_zeroMatch() throws {
        let reader = try makeReader(logicalCount: 5)
        let count = try reader.searchCount(
            SearchParameters(query: "no_such_zzqx", field: .subject, limit: 50), dedup: false)
        XCTAssertEqual(count, 0)
    }

    // MARK: - backward-compat: full path unchanged alongside the new projections

    func testFullSearchPageStillReturnsObjects() throws {
        let reader = try makeReader(logicalCount: 3)
        let page = try reader.searchPage(params(limit: 10))
        XCTAssertEqual(page.results.count, 3)
        // Full path still carries the rich fields the id projection omits.
        XCTAssertFalse(page.results[0].subject.isEmpty)
    }
}
