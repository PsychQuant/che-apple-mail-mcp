import XCTest
import SQLite3
@testable import MailSQLite

/// #472 — the store side of the experimental direct-draft path, exercised on a
/// BACKUP COPY of the live Envelope Index (the real schema and triggers; the
/// live file is only read). Skipped when the store cannot be opened.
final class DraftStoreWriterTests: XCTestCase {

    private static var copyPath: String?
    private static var copyDir: URL?

    override class func tearDown() {
        if let dir = copyDir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    /// One consistent snapshot per class via the SQLite backup API.
    private func snapshot() throws -> String {
        if let p = Self.copyPath { return p }
        let live = try realEnvelopeIndexPathOrSkip()
        // Opening can succeed while reads are denied (no Full Disk Access for
        // the test process): then the backup copies nothing. Skip honestly.
        guard (scalar(live, "SELECT count(*) FROM mailboxes") ?? 0) > 0 else {
            throw XCTSkip("the live Envelope Index opens but cannot be read from this test process (Full Disk Access?)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Envelope Index").path
        var src: OpaquePointer?, dst: OpaquePointer?
        guard sqlite3_open_v2(live, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(dest, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw XCTSkip("could not open the live store or the copy")
        }
        let backup = sqlite3_backup_init(dst, "main", src, "main")
        let stepRC = sqlite3_backup_step(backup, -1)
        let finishRC = sqlite3_backup_finish(backup)
        let err = String(cString: sqlite3_errmsg(dst))
        // The source is WAL-mode and so is the copy; fold it into one file so
        // read-only connections see every page.
        sqlite3_exec(dst, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        sqlite3_close(src); sqlite3_close(dst)
        // A failed copy must fail loudly, not turn every test into a skip.
        XCTAssertEqual(stepRC, SQLITE_DONE, "backup step failed: \(err)")
        XCTAssertEqual(finishRC, SQLITE_OK, "backup finish failed: \(err)")
        let mailboxes = scalar(dest, "SELECT count(*) FROM mailboxes") ?? 0
        XCTAssertGreaterThan(mailboxes, 0, "the backup copy has no mailboxes")
        Self.copyPath = dest; Self.copyDir = dir
        return dest
    }

    private func scalar(_ path: String, _ sql: String) -> Int64? {
        var db: OpaquePointer?; var st: OpaquePointer?
        defer { sqlite3_finalize(st); sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW,
              sqlite3_column_type(st, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(st, 0)
    }

    private func text(_ path: String, _ sql: String) -> String? {
        var db: OpaquePointer?; var st: OpaquePointer?
        defer { sqlite3_finalize(st); sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW,
              let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    /// An IMAP mailbox with messages, one of its senders, and a fake on-disk
    /// store for it under a temporary mail root.
    private func fixture(_ db: String) throws -> (mailbox: Int64, url: String, sender: Int64, root: URL) {
        guard let mailbox = scalar(db, """
            SELECT mb.ROWID FROM mailboxes mb WHERE mb.url LIKE 'imap://%'
            AND EXISTS (SELECT 1 FROM messages m WHERE m.mailbox = mb.ROWID) ORDER BY mb.ROWID LIMIT 1
            """),
            let url = text(db, "SELECT url FROM mailboxes WHERE ROWID = \(mailbox)"),
            let sender = scalar(db, "SELECT sender FROM messages WHERE mailbox = \(mailbox) AND sender IS NOT NULL LIMIT 1"),
            let parsed = MailboxURL.decode(url) else {
            throw XCTSkip("no IMAP mailbox with messages in this store")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft-writer-root-\(UUID().uuidString)")
        var dir = root.appendingPathComponent(parsed.accountUUID)
        for c in parsed.pathComponents { dir = dir.appendingPathComponent("\(c).mbox") }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("5FCC6F13-2CE3-48B1-907D-686244C0229A/Data"), withIntermediateDirectories: true)
        return (mailbox, url, sender, root)
    }

    private func draft(_ f: (mailbox: Int64, url: String, sender: Int64, root: URL)) -> DraftStoreWriter.Draft {
        DraftStoreWriter.Draft(
            mailboxRowId: f.mailbox, mailboxURL: f.url, senderAddressRowId: f.sender,
            toAddresses: ["probe-a@example.invalid", "probe-b@example.invalid"],
            subject: "[idd-472-test] writer \(UUID().uuidString)",
            messageIdHash: 1_571_834_967_991_677_254, messageIdHeader: "<0E5F3C1A-1111-4222-8333-944455556666@example.org>",
            documentUUID: UUID(), size: 1234, flags: 8_623_685_697, date: Date(timeIntervalSince1970: 1_791_083_098))
    }

    func testInsertWritesEveryRowAndTheFileThenRollbackRestoresAll() throws {
        let db = try snapshot()
        let f = try fixture(db)
        let original = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = f.root.path
        defer { EnvelopeIndexReader.mailStoragePathOverride = original; try? FileManager.default.removeItem(at: f.root) }

        let countBefore = try XCTUnwrap(scalar(db, "SELECT total_count FROM mailboxes WHERE ROWID = \(f.mailbox)"))
        let wtgBefore = try XCTUnwrap(scalar(db, "SELECT value FROM properties WHERE key = 'WriteTransactionGeneration'"))
        let fkBefore = scalar(db, "SELECT count(*) FROM pragma_foreign_key_check") ?? 0
        let emlx = Data("1234      \nfake message bytes".utf8)

        let writer = try DraftStoreWriter(databasePath: db)
        XCTAssertEqual(writer.schemaDrift(), [], "the verified schema must match this store")
        let d = draft(f)
        let ins = try writer.insert(d, emlx: emlx)

        XCTAssertEqual(scalar(db, "SELECT mailbox FROM messages WHERE ROWID = \(ins.messageRowId)"), f.mailbox)
        XCTAssertEqual(scalar(db, "SELECT flags FROM messages WHERE ROWID = \(ins.messageRowId)"), 8_623_685_697)
        XCTAssertNil(scalar(db, "SELECT remote_id FROM messages WHERE ROWID = \(ins.messageRowId)"))
        XCTAssertEqual(scalar(db, "SELECT message_id FROM messages WHERE ROWID = \(ins.messageRowId)"), 1_571_834_967_991_677_254)
        XCTAssertEqual(text(db, "SELECT s.subject FROM messages m JOIN subjects s ON s.ROWID = m.subject WHERE m.ROWID = \(ins.messageRowId)"), d.subject)
        XCTAssertEqual(text(db, "SELECT message_id_header FROM message_global_data WHERE ROWID = \(ins.globalDataRowId)"), d.messageIdHeader)
        XCTAssertEqual(scalar(db, "SELECT count(*) FROM recipients WHERE message = \(ins.messageRowId) AND type = 0"), 2)
        XCTAssertEqual(scalar(db, "SELECT action_type FROM local_message_actions WHERE ROWID = \(ins.actionRowId)"), 2)
        XCTAssertEqual(scalar(db, "SELECT destination_message FROM action_messages WHERE action = \(ins.actionRowId)"), ins.messageRowId)
        XCTAssertEqual(scalar(db, "SELECT total_count FROM mailboxes WHERE ROWID = \(f.mailbox)"), countBefore + 1,
                       "Mail's own triggers keep the mailbox count")
        XCTAssertEqual(scalar(db, "SELECT value FROM properties WHERE key = 'WriteTransactionGeneration'"), wtgBefore + 1)
        XCTAssertEqual(scalar(db, "SELECT count(*) FROM pragma_foreign_key_check") ?? 0, fkBefore)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ins.emlxPath)), emlx)
        let state = writer.uploadState(ins)
        XCTAssertNil(state.remoteId); XCTAssertTrue(state.actionQueued)

        try writer.rollback(ins)
        XCTAssertNil(scalar(db, "SELECT ROWID FROM messages WHERE ROWID = \(ins.messageRowId)"))
        XCTAssertEqual(scalar(db, "SELECT count(*) FROM recipients WHERE message = \(ins.messageRowId)"), 0)
        XCTAssertNil(scalar(db, "SELECT ROWID FROM local_message_actions WHERE ROWID = \(ins.actionRowId)"))
        XCTAssertEqual(scalar(db, "SELECT count(*) FROM action_messages WHERE destination_message = \(ins.messageRowId)"), 0)
        XCTAssertEqual(scalar(db, "SELECT total_count FROM mailboxes WHERE ROWID = \(f.mailbox)"), countBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ins.emlxPath))
    }

    func testRollbackRefusesOnceTheServerHasTheMessage() throws {
        let db = try snapshot()
        let f = try fixture(db)
        let original = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = f.root.path
        defer { EnvelopeIndexReader.mailStoragePathOverride = original; try? FileManager.default.removeItem(at: f.root) }
        let writer = try DraftStoreWriter(databasePath: db)
        let ins = try writer.insert(draft(f), emlx: Data("x".utf8))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(db, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "INSERT INTO server_messages(message, mailbox, read, deleted, replied, flagged, draft, forwarded, redirected, junk_level_set_by_user, junk_level, flag_color, remote_id) VALUES (\(ins.messageRowId), \(f.mailbox), 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 999999)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertThrowsError(try writer.rollback(ins), "Mail already uploaded it: clean up through Mail, not SQL")
        XCTAssertNotNil(scalar(db, "SELECT ROWID FROM messages WHERE ROWID = \(ins.messageRowId)"))
    }

    func testInsertLeavesNothingBehindWhenTheFileCannotBeWritten() throws {
        let db = try snapshot()
        let f = try fixture(db)
        let original = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = f.root.appendingPathComponent("elsewhere").path  // no store dir
        defer { EnvelopeIndexReader.mailStoragePathOverride = original; try? FileManager.default.removeItem(at: f.root) }
        let seqBefore = scalar(db, "SELECT seq FROM sqlite_sequence WHERE name = 'messages'")
        let countBefore = scalar(db, "SELECT total_count FROM mailboxes WHERE ROWID = \(f.mailbox)")
        let writer = try DraftStoreWriter(databasePath: db)
        XCTAssertThrowsError(try writer.insert(draft(f), emlx: Data("x".utf8)))
        XCTAssertEqual(scalar(db, "SELECT seq FROM sqlite_sequence WHERE name = 'messages'"), seqBefore)
        XCTAssertEqual(scalar(db, "SELECT total_count FROM mailboxes WHERE ROWID = \(f.mailbox)"), countBefore)
    }

    func testLooksUpTheSenderRowAndTheMailboxRowForAnAccount() throws {
        let db = try snapshot()
        let f = try fixture(db)
        let writer = try DraftStoreWriter(databasePath: db)
        let parsed = try XCTUnwrap(MailboxURL.decode(f.url))
        let row = try XCTUnwrap(writer.mailboxRow(accountUUID: parsed.accountUUID, pathComponents: parsed.pathComponents))
        XCTAssertEqual(row.rowId, f.mailbox)
        XCTAssertEqual(row.url, f.url)
        let address = try XCTUnwrap(text(db, "SELECT address FROM addresses WHERE ROWID = \(f.sender)"))
        let sender = writer.senderRow(address: address.uppercased(), accountUUID: parsed.accountUUID)
        XCTAssertNotNil(sender, "case-insensitive lookup of an address the account has sent from")
    }

    func testSchemaDriftIsReportedForAnUnknownStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("x.sqlite").path
        var raw: OpaquePointer?
        sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_exec(raw, "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, extra_new_column TEXT)", nil, nil, nil)
        sqlite3_close(raw)
        let drift = try DraftStoreWriter(databasePath: path).schemaDrift()
        XCTAssertTrue(drift.contains { $0.contains("messages") }, "\(drift)")
        XCTAssertTrue(drift.contains { $0.contains("local_message_actions") }, "missing tables are reported: \(drift)")
    }
}
