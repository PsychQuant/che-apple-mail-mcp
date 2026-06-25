import XCTest
import SQLite3
@testable import MailSQLite

/// #209 — deterministic tie-break when multiple results share the same
/// `date_received` (second granularity). Without a secondary `ORDER BY` key the
/// relative order of same-second rows is unspecified, so which row sits on the
/// `limit`/`limit+1` truncation boundary is nondeterministic. The fix adds
/// `, m.ROWID <dir>` (and `MIN(m.ROWID) <dir>` for the dedup branch) so the order
/// is total + deterministic across `searchPage` / `searchIds` (both branches).
final class SearchTieBreakTests: XCTestCase {

    /// Fixture: `count` messages ALL sharing `date_received = 5000` (a tie), with
    /// distinct ROWIDs `1...count` and distinct subjects all containing "match"
    /// (distinct so the dedup `GROUP BY subject/sender/date` keeps all `count`).
    private func makeSameDateReader(count: Int) throws -> EnvelopeIndexReader {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "SearchTieBreakTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            throw NSError(domain: "SearchTieBreakTests", code: 1,
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
        for i in 1...count {
            sql += "INSERT INTO subjects (ROWID, subject) VALUES (\(i), 'match topic \(i)');\n"
            sql += "INSERT INTO messages (ROWID, subject, sender, mailbox, date_received, deleted) VALUES (\(i), \(i), 1, 1, 5000, 0);\n"
        }

        var errMsg: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let m = errMsg.map { String(cString: $0) } ?? "unknown"
            throw NSError(domain: "SearchTieBreakTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "exec failed: \(m)"])
        }
        return try EnvelopeIndexReader(databasePath: dbPath, accountMapping: ["UUID-A": "Alice"])
    }

    private func params(_ sort: MailSQLite.SortOrder, limit: Int) -> SearchParameters {
        SearchParameters(query: "match", field: .subject, sort: sort, limit: limit)
    }

    // MARK: - searchPage

    func testSearchPage_sameDate_descBreaksByRowidDescending() throws {
        let reader = try makeSameDateReader(count: 4)
        let ids = try reader.searchPage(params(.desc, limit: 10)).results.map(\.id)
        XCTAssertEqual(ids, [4, 3, 2, 1], "same-second ties must break by ROWID descending for sort=desc")
    }

    func testSearchPage_sameDate_ascBreaksByRowidAscending() throws {
        let reader = try makeSameDateReader(count: 4)
        let ids = try reader.searchPage(params(.asc, limit: 10)).results.map(\.id)
        XCTAssertEqual(ids, [1, 2, 3, 4], "same-second ties must break by ROWID ascending for sort=asc")
    }

    func testSearchPage_sameDate_truncationBoundaryDeterministic() throws {
        // The #209 core concern: which rows sit on the limit boundary must be deterministic.
        let reader = try makeSameDateReader(count: 4)
        let ids = try reader.searchPage(params(.desc, limit: 2)).results.map(\.id)
        XCTAssertEqual(ids, [4, 3], "limit=2 desc must deterministically return the two highest ROWIDs")
    }

    // MARK: - searchIds (both branches)

    func testSearchIds_sameDate_nonDedup_deterministic() throws {
        let reader = try makeSameDateReader(count: 4)
        let result = try reader.searchIds(params(.desc, limit: 10), dedup: false)
        XCTAssertEqual(result.ids, [4, 3, 2, 1])
    }

    func testSearchIds_sameDate_dedup_deterministic() throws {
        // Distinct subjects → dedup keeps all 4 (GROUP BY subject/sender/date);
        // ties break by the MIN(ROWID) representative in sort direction.
        let reader = try makeSameDateReader(count: 4)
        let result = try reader.searchIds(params(.desc, limit: 10), dedup: true)
        XCTAssertEqual(result.ids, [4, 3, 2, 1], "dedup branch ties must break by MIN(ROWID) in sort direction")
    }
}
