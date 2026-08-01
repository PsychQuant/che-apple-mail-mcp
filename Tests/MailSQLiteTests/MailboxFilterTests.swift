import XCTest
import SQLite3
@testable import MailSQLite

/// #317 — the SQLite mailbox filter used encode-then-LIKE with no ESCAPE
/// clause, so every `%XX` produced by percent-encoding (and any literal `%`/`_`
/// in a mailbox name) acted as a wildcard instead of data. Consequences:
/// over-matching (a `_` in the query matches ANY character — `Se_t` matched
/// `Sent`), and an unauditable relationship between what `search_emails`
/// RETURNS in its `mailbox` field and what it ACCEPTS as a filter.
///
/// The fix resolves mailbox ROWIDs on the DECODE side: enumerate mailbox rows,
/// decode each URL with the same `MailboxURL.decode` that produces the
/// `mailbox` strings in search results, and compare paths exactly — so
/// "feed the tool's own output back in" succeeds by construction, and no
/// string ever doubles as query syntax.
///
/// These tests were the missing coverage: the SQLite mailbox filter previously
/// had ZERO unit tests (the AppleScript fallback's nested/CJK handling was
/// well-tested; the fast path was not).
final class MailboxFilterTests: XCTestCase {

    // MARK: - fixture

    /// Hermetic Envelope Index with Gmail-style percent-encoded URLs (the real
    /// on-disk format, verified against a live index in the #317 diagnosis).
    private func makeFixtureDB() throws -> String {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "MailboxFilterTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                              nil) == SQLITE_OK else {
            throw NSError(domain: "MailboxFilterTests", code: 1)
        }
        defer { sqlite3_close(db) }

        // Mailboxes:
        //  1  UUID-A  [Gmail]/寄件備份      (bracketed + CJK nested — the issue's shape)
        //  2  UUID-A  [Gmail]/寄件備份/sub  (descendant of 1)
        //  3  UUID-A  INBOX
        //  4  UUID-A  Se_t                 (literal underscore in the name)
        //  5  UUID-A  Sent                 (over-match victim: `_` wildcard hits it)
        //  6  UUID-B  [Gmail]/寄件備份      (same path, DIFFERENT account)
        // One message per mailbox, subjects all contain "match".
        let sql = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, unread_count INTEGER DEFAULT 0);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER, date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        INSERT INTO addresses VALUES (1, 'sender@example.com', 'Sender');
        INSERT INTO mailboxes VALUES (1, 'imap://UUID-A/%5BGmail%5D/%E5%AF%84%E4%BB%B6%E5%82%99%E4%BB%BD', 3);
        INSERT INTO mailboxes VALUES (2, 'imap://UUID-A/%5BGmail%5D/%E5%AF%84%E4%BB%B6%E5%82%99%E4%BB%BD/sub', 0);
        INSERT INTO mailboxes VALUES (3, 'imap://UUID-A/INBOX', 5);
        INSERT INTO mailboxes VALUES (4, 'imap://UUID-A/Se_t', 1);
        INSERT INTO mailboxes VALUES (5, 'imap://UUID-A/Sent', 2);
        INSERT INTO mailboxes VALUES (6, 'imap://UUID-B/%5BGmail%5D/%E5%AF%84%E4%BB%B6%E5%82%99%E4%BB%BD', 0);
        INSERT INTO subjects VALUES (1, 'match one');
        INSERT INTO messages (ROWID, subject, sender, mailbox, date_received) VALUES
            (1, 1, 1, 1, 1001), (2, 1, 1, 2, 1002), (3, 1, 1, 3, 1003),
            (4, 1, 1, 4, 1004), (5, 1, 1, 5, 1005), (6, 1, 1, 6, 1006);
        """
        var err: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "?"
            throw NSError(domain: "MailboxFilterTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: m])
        }
        return dbPath
    }

    private func makeReader() throws -> EnvelopeIndexReader {
        try EnvelopeIndexReader(databasePath: try makeFixtureDB(),
                                accountMapping: ["UUID-A": "Alice", "UUID-B": "Bob"])
    }

    private func count(_ reader: EnvelopeIndexReader, mailbox: String,
                       account: String? = nil) throws -> Int {
        try reader.searchCount(SearchParameters(
            query: "match", field: .subject,
            accountName: account, mailbox: mailbox, limit: 100))
    }

    // MARK: - the over-match pin (#317 Bug A — deterministic RED on encode+LIKE)

    /// A literal `_` in the queried name must not act as a single-char wildcard.
    /// Under encode+LIKE, querying `Se_t` matched BOTH `Se_t` and `Sent`.
    func testLiteralUnderscore_doesNotWildcardMatch() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "Se_t"), 1,
            "'Se_t' must match only the mailbox literally named Se_t — under the old "
            + "LIKE pattern the _ matched any character and Sent's messages leaked in (#317)")
        XCTAssertEqual(try count(reader, mailbox: "Sent"), 1,
            "'Sent' must not pick up Se_t either")
    }

    // MARK: - round-trip: the tool accepts its own output

    /// The exact bracketed+CJK full path that search results carry in their
    /// `mailbox` field must resolve — matching that mailbox and its descendants
    /// (the pre-existing two-pattern semantics, minus the injection).
    func testBracketedCJKFullPath_roundTrips() throws {
        let reader = try makeReader()
        // mailbox 1 (self) + mailbox 2 (descendant) + mailbox 6 (same path, other account)
        XCTAssertEqual(try count(reader, mailbox: "[Gmail]/寄件備份"), 3)
        // Scoped to one account: self + descendant only.
        XCTAssertEqual(try count(reader, mailbox: "[Gmail]/寄件備份", account: "Alice"), 2)
    }

    /// Leaf-name queries keep working (suffix-at-boundary semantics).
    func testLeafName_matchesNestedMailbox() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "寄件備份"), 3,
            "a bare leaf must still match the nested mailbox (and its descendants), as before")
        XCTAssertEqual(try count(reader, mailbox: "INBOX"), 1)
    }

    /// An unresolvable name yields an honest empty, not an error and not junk.
    func testUnknownMailbox_returnsZero() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "NoSuchBox"), 0)
    }

    // MARK: - the same fix must cover the sibling call sites

    func testGetUnreadCount_literalUnderscore() throws {
        let reader = try makeReader()
        XCTAssertEqual(try reader.getUnreadCount(mailbox: "Se_t", accountName: nil), 1,
            "getUnreadCount shared the encode+LIKE block — Se_t must not absorb Sent's "
            + "unread count (#317)")
        XCTAssertEqual(try reader.getUnreadCount(mailbox: "Sent", accountName: nil), 2)
    }

    func testListEmails_literalUnderscore() throws {
        let reader = try makeReader()
        let rows = try reader.listEmails(mailbox: "Se_t", accountName: "Alice", limit: 50)
        XCTAssertEqual(rows.count, 1,
            "listEmails shared the encode+LIKE block — Se_t must return only its own row (#317)")
    }
}
