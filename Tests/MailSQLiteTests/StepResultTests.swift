import XCTest
import SQLite3
@testable import MailSQLite

/// #549 — every read used to stop at the first `sqlite3_step` result that was
/// not `SQLITE_ROW`, so a step-phase failure (`SQLITE_BUSY` after the busy
/// timeout, `SQLITE_IOERR`, `SQLITE_CORRUPT`) read as "no more rows" and the
/// partial result came back as if complete.
///
/// The fixtures put one large table last in the file and overwrite the file's
/// last page, which belongs to that table. Reading the table then returns the
/// rows on the intact pages and fails with `SQLITE_CORRUPT` part-way through:
/// a step-phase failure that needs no hook into the reader's connection.
final class StepResultTests: XCTestCase {

    private static let rowCount = 3000

    private enum LargeTable { case mailboxes, messages }

    private func makeFixture(large: LargeTable, corrupt: Bool) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("StepResultTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Envelope Index").path

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "StepResultTests", code: 1)
        }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "StepResultTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        try exec("PRAGMA page_size = 512")
        try exec("""
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
            CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
            INSERT INTO subjects VALUES (1, 'hello');
            INSERT INTO addresses VALUES (1, 'sender@example.com', 'Sender');
            """)
        let mailboxes = "CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER, unread_count INTEGER)"
        let messages = """
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER,
                date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
                size INTEGER DEFAULT 0, conversation_id INTEGER DEFAULT 0, padding TEXT)
            """
        try exec("BEGIN")
        switch large {
        case .mailboxes:
            try exec(messages)
            try exec(mailboxes)
            for i in 1...Self.rowCount {
                try exec("INSERT INTO mailboxes VALUES (\(i), 'imap://UUID-A/Folder-\(String(format: "%05d", i))-\(String(repeating: "x", count: 60))', 1, 1)")
            }
        case .messages:
            try exec(mailboxes)
            try exec("INSERT INTO mailboxes VALUES (1, 'imap://UUID-A/INBOX', 1, 1)")
            try exec(messages)
            for i in 1...Self.rowCount {
                try exec("INSERT INTO messages VALUES (\(i), 1, 1, 1, 1700000000, 0, 0, 0, 10, 0, '\(String(repeating: "y", count: 60))')")
            }
        }
        try exec("COMMIT")
        sqlite3_close(db)

        if corrupt {
            let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size - 512)
            handle.write(Data(repeating: 0xFF, count: 512))
            try handle.close()
        }
        return path
    }

    private func reader(_ path: String) throws -> EnvelopeIndexReader {
        try EnvelopeIndexReader(databasePath: path, accountMapping: ["UUID-A": "Alice"])
    }

    private func assertStepFailure<T>(_ expression: @autoclosure () throws -> T,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case MailSQLiteError.queryFailed(let message) = error else {
                return XCTFail("expected queryFailed, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains("stopped before the end of its results"), message, file: file, line: line)
            XCTAssertTrue(message.contains("SQLite result code"), message, file: file, line: line)
        }
    }

    // MARK: - multi-row reads

    func testIntactFixtureReadsEveryRow() throws {
        let reader = try reader(try makeFixture(large: .mailboxes, corrupt: false))
        XCTAssertEqual(try reader.listMailboxes().count, Self.rowCount)
        XCTAssertEqual(try reader.getUnreadCount(), Self.rowCount)
    }

    func testListMailboxesThrowsInsteadOfReturningAPartialList() throws {
        let reader = try reader(try makeFixture(large: .mailboxes, corrupt: true))
        assertStepFailure(try reader.listMailboxes())
        assertStepFailure(try reader.listMailboxes(accountName: "Alice"))
    }

    func testMailboxResolutionThrowsInsteadOfMatchingFromAPartialScan() throws {
        let reader = try reader(try makeFixture(large: .mailboxes, corrupt: true))
        // The match is on the last page: a partial scan used to report "no mailbox".
        let lastFolder = "Folder-\(String(format: "%05d", Self.rowCount))-\(String(repeating: "x", count: 60))"
        assertStepFailure(try reader.listEmailsPage(mailbox: lastFolder, accountName: "Alice"))
        assertStepFailure(try reader.searchIds(SearchParameters(query: "", mailbox: lastFolder)))
        assertStepFailure(try reader.searchCount(SearchParameters(query: "", mailbox: lastFolder)))
    }

    func testSearchThrowsInsteadOfReturningAPartialPage() throws {
        let reader = try reader(try makeFixture(large: .messages, corrupt: true))
        assertStepFailure(try reader.searchIds(SearchParameters(query: "", limit: Self.rowCount + 10)))
        assertStepFailure(try reader.searchPage(SearchParameters(query: "", limit: Self.rowCount + 10)))
        assertStepFailure(try reader.searchSummaryPage(SearchParameters(query: "", limit: Self.rowCount + 10)))
    }

    // MARK: - one-row reads

    func testUnreadCountThrowsInsteadOfReturningZero() throws {
        let reader = try reader(try makeFixture(large: .mailboxes, corrupt: true))
        assertStepFailure(try reader.getUnreadCount())
    }

    func testSearchCountThrowsInsteadOfReturningZero() throws {
        let reader = try reader(try makeFixture(large: .messages, corrupt: true))
        assertStepFailure(try reader.searchCount(SearchParameters(query: "")))
    }

    func testMessageOnACorruptPageIsAFailureNotAMissingMessage() throws {
        let reader = try reader(try makeFixture(large: .messages, corrupt: true))
        // The last message lives on the overwritten page.
        assertStepFailure(try reader.mailboxURL(forMessageId: Self.rowCount))
        assertStepFailure(try reader.getEmailMetadata(messageId: Self.rowCount))
    }

    func testMissingMessageIsStillReportedAsMissing() throws {
        let reader = try reader(try makeFixture(large: .messages, corrupt: false))
        XCTAssertNil(try reader.mailboxURL(forMessageId: Self.rowCount + 1))
        XCTAssertThrowsError(try reader.getEmailMetadata(messageId: Self.rowCount + 1)) { error in
            guard case MailSQLiteError.queryFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("not found"), message)
        }
        XCTAssertEqual(try reader.searchCount(SearchParameters(query: "")), Self.rowCount)
    }
}
