import Darwin
import XCTest
import SQLite3
@testable import MailSQLite

/// #503 — the directories a direct write creates for its `.emlx` file are removed again when the
/// write does not stand: a later step fails, placing the file fails, or a committed write is
/// reversed. Only the levels this write created go, only while empty, deepest first.
///
/// The store is a small synthetic one with the tables and columns the writer verifies (never a
/// copy of the real store), so these run without Full Disk Access. Its last message row is 19999:
/// the next one, 20000, goes to `Data/0/2/Messages/20000.emlx`, three levels below `Data`.
final class DraftStoreWriterDirectoryTests: XCTestCase {

    private static let account = "11111111-2222-4333-8444-555555555555"
    private static let storeUUID = "5FCC6F13-2CE3-48B1-907D-686244C0229A"
    private static let rowId: Int64 = 20000

    private var root: URL!
    private var originalOverride: String?

    private var databasePath: String { root.appendingPathComponent("Envelope Index").path }
    private var mailRoot: URL { root.appendingPathComponent("Mail") }
    private var dataDir: String {
        mailRoot.appendingPathComponent("\(Self.account)/Drafts.mbox/\(Self.storeUUID)/Data").path
    }
    private var level0: String { dataDir + "/0" }
    private var level02: String { dataDir + "/0/2" }
    private var messagesDir: String { dataDir + "/0/2/Messages" }
    private var emlxPath: String { messagesDir + "/\(Self.rowId).emlx" }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("draft-dirs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        let columns = DraftStoreWriter.verifiedMessageColumns.dropFirst().joined(separator: ", ")
        try exec("""
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, \(columns));
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER DEFAULT 0, unread_count INTEGER DEFAULT 0);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT, UNIQUE(address, comment));
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT UNIQUE);
            CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id, validation_state, model_high_impact, message_id_header);
            CREATE TABLE conversations (conversation_id INTEGER PRIMARY KEY, flags, sync_key);
            CREATE TABLE conversation_id_message_id (conversation_id, message_id, date_sent);
            CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message, address, type, position);
            CREATE TABLE searchable_messages (message_id, message, transaction_id, message_body_indexed, reindex_type);
            CREATE TABLE local_message_actions (ROWID INTEGER PRIMARY KEY, mailbox, source_mailbox, destination_mailbox, action_type, user_initiated);
            CREATE TABLE action_messages (action, action_phase, message, remote_id, destination_message);
            CREATE TABLE properties (key TEXT, value);
            CREATE TABLE server_messages (message, mailbox);
            INSERT INTO properties VALUES ('WriteTransactionGeneration', 1);
            INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://\(Self.account)/Drafts');
            INSERT INTO addresses (ROWID, address, comment) VALUES (1, 'me@example.invalid', 'Fixture Sender');
            INSERT INTO messages (ROWID, message_id, sender, subject, mailbox, read) VALUES (\(Self.rowId - 1), 1, 1, 0, 1, 1);
            """)
        originalOverride = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = mailRoot.path
    }

    override func tearDown() {
        EnvelopeIndexReader.mailStoragePathOverride = originalOverride
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(databasePath, &db) == SQLITE_OK,
              sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "DraftStoreWriterDirectoryTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func messageRows() -> Int64? {
        var db: OpaquePointer?, st: OpaquePointer?
        defer { sqlite3_finalize(st); sqlite3_close(db) }
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT count(*) FROM messages", -1, &st, nil) == SQLITE_OK,
              sqlite3_step(st) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(st, 0)
    }

    private func draft() -> DraftStoreWriter.Draft {
        DraftStoreWriter.Draft(
            mailboxRowId: 1, mailboxURL: "imap://\(Self.account)/Drafts", senderAddressRowId: 1,
            toAddresses: ["probe@example.invalid"], subject: "[idd-503-test] \(UUID().uuidString)",
            messageIdHash: 42, messageIdHeader: "<503@example.invalid>", documentUUID: UUID(),
            size: 10, flags: 0, date: Date(timeIntervalSince1970: 1_791_083_098))
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Makes the step after placement fail: `insert` reads this property once the file is placed.
    private func failAfterPlacement() throws {
        try exec("DELETE FROM properties WHERE key = 'WriteTransactionGeneration'")
    }

    struct HookFailure: Error, Equatable {}

    // MARK: - Examples

    // spec-example: message-composition / a new hash block is removed after a later step fails
    func testANewHashBlockIsRemovedAfterALaterStepFails() throws {
        try failAfterPlacement()
        let writer = try DraftStoreWriter(databasePath: databasePath)
        var sawPlacedFile = false
        writer.placementHook = { [emlxPath] step in
            if case .filePlaced(let path) = step {
                XCTAssertEqual(path, emlxPath)
                sawPlacedFile = FileManager.default.fileExists(atPath: path)
            }
        }
        XCTAssertThrowsError(try writer.insert(draft(), emlx: Data("x".utf8))) {
            XCTAssertEqual($0 as? DraftStoreWriter.WriteError, .sql("no WriteTransactionGeneration"))
        }
        XCTAssertTrue(sawPlacedFile, "the failure must come after the file was placed")
        XCTAssertFalse(exists(emlxPath))
        XCTAssertFalse(exists(messagesDir))
        XCTAssertFalse(exists(level02))
        XCTAssertFalse(exists(level0))
        XCTAssertTrue(exists(dataDir), "a level that existed before the write stays")
        XCTAssertEqual(messageRows(), 1)
    }

    // spec-example: message-composition / a failure while placing the file removes the new directories
    func testAFailureWhilePlacingTheFileRemovesTheNewDirectories() throws {
        let writer = try DraftStoreWriter(databasePath: databasePath)
        var sawDirectories = false
        writer.placementHook = { [messagesDir] step in
            if case .directoriesReady(let dir) = step {
                XCTAssertEqual(dir, messagesDir)
                sawDirectories = FileManager.default.fileExists(atPath: dir)
                throw HookFailure()
            }
        }
        XCTAssertThrowsError(try writer.insert(draft(), emlx: Data("x".utf8))) {
            XCTAssertEqual($0 as? HookFailure, HookFailure())
        }
        XCTAssertTrue(sawDirectories, "the failure must come after the directories were created")
        XCTAssertFalse(exists(level0))
        XCTAssertTrue(exists(dataDir))
        XCTAssertEqual(messageRows(), 1)
    }

    // spec-example: message-composition / another file in the new Messages directory survives a failed write
    func testAnotherFileInTheNewMessagesDirectorySurvivesAFailedWrite() throws {
        try failAfterPlacement()
        let other = messagesDir + "/\(Self.rowId + 1).emlx"
        let writer = try DraftStoreWriter(databasePath: databasePath)
        writer.placementHook = { step in
            if case .filePlaced = step { try Data("mail".utf8).write(to: URL(fileURLWithPath: other)) }
        }
        XCTAssertThrowsError(try writer.insert(draft(), emlx: Data("x".utf8))) {
            XCTAssertEqual($0 as? DraftStoreWriter.WriteError, .sql("no WriteTransactionGeneration"))
        }
        XCTAssertFalse(exists(emlxPath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: other)), Data("mail".utf8))
        XCTAssertTrue(exists(messagesDir))
        XCTAssertTrue(exists(level02))
        XCTAssertTrue(exists(level0))
    }

    // spec-example: message-composition / another file in the new Messages directory survives a reversal
    func testAnotherFileInTheNewMessagesDirectorySurvivesAReversal() throws {
        let writer = try DraftStoreWriter(databasePath: databasePath)
        let ins = try writer.insert(draft(), emlx: Data("x".utf8))
        let other = messagesDir + "/\(Self.rowId + 1).emlx"
        try Data("mail".utf8).write(to: URL(fileURLWithPath: other))
        XCTAssertNoThrow(try writer.rollback(ins))
        XCTAssertFalse(exists(emlxPath))
        XCTAssertTrue(exists(other))
        XCTAssertTrue(exists(messagesDir))
        XCTAssertTrue(exists(level0))
        XCTAssertEqual(messageRows(), 1)
    }

    // spec-example: message-composition / reversal removes only the levels the write created
    func testReversalRemovesOnlyTheLevelsTheWriteCreated() throws {
        try FileManager.default.createDirectory(atPath: level0, withIntermediateDirectories: false)
        let writer = try DraftStoreWriter(databasePath: databasePath)
        let ins = try writer.insert(draft(), emlx: Data("x".utf8))
        XCTAssertEqual(ins.createdDirectories, [level02, messagesDir])
        try writer.rollback(ins)
        XCTAssertFalse(exists(emlxPath))
        XCTAssertFalse(exists(level02))
        XCTAssertTrue(exists(level0), "a level that existed before the write stays")
        XCTAssertEqual(messageRows(), 1)
    }

    // spec-example: message-composition / an existing 20000.emlx is left as it was
    func testAnExisting20000EmlxIsLeftAsItWas() throws {
        try FileManager.default.createDirectory(atPath: messagesDir, withIntermediateDirectories: true)
        try Data("someone else's".utf8).write(to: URL(fileURLWithPath: emlxPath))
        let writer = try DraftStoreWriter(databasePath: databasePath)
        XCTAssertThrowsError(try writer.insert(draft(), emlx: Data("x".utf8))) {
            XCTAssertEqual($0 as? DraftStoreWriter.WriteError, .emlxExists(emlxPath))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: emlxPath)), Data("someone else's".utf8))
        XCTAssertTrue(exists(messagesDir))
        XCTAssertEqual(messageRows(), 1)
    }

    // spec-example: message-composition / a vanished Messages directory does not stop the cleanup
    func testAVanishedMessagesDirectoryDoesNotStopTheCleanup() throws {
        let writer = try DraftStoreWriter(databasePath: databasePath)
        let ins = try writer.insert(draft(), emlx: Data("x".utf8))
        XCTAssertEqual(ins.createdDirectories, [level0, level02, messagesDir])
        try FileManager.default.removeItem(atPath: emlxPath)
        try FileManager.default.removeItem(atPath: messagesDir)
        XCTAssertNoThrow(try writer.rollback(ins))
        XCTAssertFalse(exists(level02), "a vanished deeper level must not stop the cleanup")
        XCTAssertFalse(exists(level0))
        XCTAssertTrue(exists(dataDir))
        XCTAssertEqual(messageRows(), 1)
    }

    // spec-example: message-composition / a permission failure on Messages is noted on stderr
    func testAPermissionFailureOnMessagesIsNotedOnStderr() throws {
        let writer = try DraftStoreWriter(databasePath: databasePath)
        let ins = try writer.insert(draft(), emlx: Data("x".utf8))
        // rmdir needs write permission on the parent: a read-only Data/0/2 makes Messages unremovable.
        XCTAssertEqual(chmod(level02, 0o555), 0)
        addTeardownBlock { [level02] in _ = chmod(level02, 0o755) }
        let log = try capturingStderr { XCTAssertNoThrow(try writer.rollback(ins)) }
        XCTAssertFalse(exists(emlxPath))
        XCTAssertTrue(exists(messagesDir))
        XCTAssertTrue(exists(level02))
        XCTAssertTrue(exists(level0))
        XCTAssertTrue(log.contains("could not remove created directory"), log)
        XCTAssertTrue(log.contains(messagesDir), log)
        XCTAssertEqual(messageRows(), 1)
    }

    /// Runs `body` with standard error pointed at a file and returns what landed there
    /// (the same approach as the server tests' helper, synchronous).
    private func capturingStderr(_ body: () throws -> Void) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stderr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = dup(STDERR_FILENO)
        guard saved >= 0 else { throw NSError(domain: "StderrCapture", code: 1) }
        defer { close(saved) }
        let sink = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard sink >= 0 else { throw NSError(domain: "StderrCapture", code: 2) }
        let redirected = dup2(sink, STDERR_FILENO)
        close(sink)
        guard redirected == STDERR_FILENO else { throw NSError(domain: "StderrCapture", code: 3) }
        var failure: Error?
        do { try body() } catch { failure = error }
        XCTAssertEqual(dup2(saved, STDERR_FILENO), STDERR_FILENO, "standard error was not restored")
        if let failure { throw failure }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The full list a fresh write records: every level below `Data`, shallowest first.
    func testAFreshWriteRecordsEveryLevelItCreated() throws {
        let writer = try DraftStoreWriter(databasePath: databasePath)
        let ins = try writer.insert(draft(), emlx: Data("x".utf8))
        XCTAssertEqual(ins.createdDirectories, [level0, level02, messagesDir])
        try writer.rollback(ins)
        XCTAssertFalse(exists(level0))
        XCTAssertTrue(exists(dataDir))
    }
}
