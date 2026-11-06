import XCTest
import SQLite3
@testable import MailSQLite

/// #618 — the writer's read helpers took any `sqlite3_step` result other than
/// the wanted one for an empty answer. For the upload check in `rollback` that
/// meant "not uploaded", the one answer the direct-write guarantees (2 and 3)
/// must never get by accident, and a mailbox scan that stopped early could
/// pass the single-row gate on the rows it had seen.
///
/// The failures are real ones, raised by SQLite while stepping:
/// - the mailbox scan, as in #549: one large table last in the file with its
///   last page overwritten, so reading it returns rows and then fails;
/// - the upload check: `server_messages` is a view whose value overflows at run
///   time. A corrupted page does not serve here. The `DELETE`s or the `COMMIT`
///   after it fail too, so the rollback throws with or without the fix and the
///   test would prove nothing.
final class DraftStoreWriterReadFailureTests: XCTestCase {

    private static let rowCount = 3000
    private static let inserted = DraftStoreWriter.Inserted(
        messageRowId: 7, conversationId: 8, globalDataRowId: 9, actionRowId: 10,
        messageIdHash: 11, emlxPath: "/nonexistent/7.emlx")

    private enum ServerMessages { case empty, uploaded, failing }

    private func makeStore(serverMessages: ServerMessages = .empty,
                           largeMailboxes: Bool = false, corrupt: Bool = false) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("DraftStoreRead-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Envelope Index").path

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "DraftStoreRead", code: 1)
        }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "DraftStoreRead", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        try exec("PRAGMA page_size = 512")
        try exec("""
            CREATE TABLE action_messages (destination_message INTEGER);
            CREATE TABLE local_message_actions (ROWID INTEGER PRIMARY KEY);
            CREATE TABLE recipients (message INTEGER);
            CREATE TABLE searchable_messages (message_id INTEGER);
            CREATE TABLE conversation_id_message_id (conversation_id INTEGER, message_id INTEGER);
            CREATE TABLE conversations (conversation_id INTEGER);
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, remote_id INTEGER);
            INSERT INTO messages VALUES (7, NULL);
            INSERT INTO conversations VALUES (8);
            """)
        switch serverMessages {
        case .failing:
            try exec("""
                CREATE VIEW server_messages AS
                SELECT abs(-9223372036854775807 - x) AS message, 0 AS mailbox FROM (SELECT 1 AS x)
                """)
        case .empty, .uploaded:
            try exec("CREATE TABLE server_messages (ROWID INTEGER PRIMARY KEY, message INTEGER, mailbox INTEGER)")
        }
        if serverMessages == .uploaded { try exec("INSERT INTO server_messages VALUES (1, 7, 1)") }
        try exec("CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT)")
        try exec("BEGIN")
        try exec("INSERT INTO mailboxes VALUES (1, 'imap://UUID-A/Drafts')")
        if largeMailboxes {
            for i in 2...Self.rowCount {
                try exec("INSERT INTO mailboxes VALUES (\(i), 'imap://UUID-A/Folder-\(i)-\(String(repeating: "x", count: 60))')")
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

    private func messageCount(_ path: String) throws -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM messages", -1, &st, nil), SQLITE_OK)
        defer { sqlite3_finalize(st) }
        XCTAssertEqual(sqlite3_step(st), SQLITE_ROW)
        return Int(sqlite3_column_int64(st, 0))
    }

    // MARK: - rollback

    func testAFailedUploadCheckRefusesTheRollbackAndDeletesNothing() throws {
        let path = try makeStore(serverMessages: .failing)
        let writer = try DraftStoreWriter(databasePath: path)
        XCTAssertThrowsError(try writer.rollback(Self.inserted)) { error in
            guard case DraftStoreWriter.WriteError.sql(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("integer overflow"), message)
        }
        XCTAssertEqual(try messageCount(path), 1, "an unknown upload state must leave the draft alone")
    }

    func testAnUploadedDraftIsStillRefused() throws {
        let path = try makeStore(serverMessages: .uploaded)
        XCTAssertThrowsError(try DraftStoreWriter(databasePath: path).rollback(Self.inserted)) { error in
            XCTAssertEqual(error as? DraftStoreWriter.WriteError, .alreadyUploaded)
        }
        XCTAssertEqual(try messageCount(path), 1)
    }

    func testAnUnuploadedDraftStillRollsBack() throws {
        let path = try makeStore()
        try DraftStoreWriter(databasePath: path).rollback(Self.inserted)
        XCTAssertEqual(try messageCount(path), 0)
    }

    // MARK: - the mailbox gate

    func testAMailboxScanThatFailsAfterTheMatchAnswersNothing() throws {
        // The match is the first row: a scan that stops early has seen exactly
        // one hit, which is what the gate passes on.
        let writer = try DraftStoreWriter(databasePath: try makeStore(largeMailboxes: true, corrupt: true))
        XCTAssertNil(writer.mailboxRow(accountUUID: "UUID-A", pathComponents: ["Drafts"]))
    }

    func testAnIntactMailboxScanFindsTheRow() throws {
        let writer = try DraftStoreWriter(databasePath: try makeStore(largeMailboxes: true))
        XCTAssertEqual(writer.mailboxRow(accountUUID: "UUID-A", pathComponents: ["Drafts"])?.rowId, 1)
    }
}
