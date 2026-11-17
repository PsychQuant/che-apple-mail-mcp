import XCTest
import SQLite3
@testable import CheAppleMailMCP
@testable import MailSQLite

/// #484 — every outcome after the write, without Mail. The path under test is the real
/// `attemptSteps` with a real `DraftStoreWriter`; only Mail is a stand-in. `FixtureDraftStore` is a
/// small SQLite file with the tables and columns the writer verifies, and the stand-in plays Mail by
/// changing that file the way Mail changes the real store.
///
/// What this cannot show: how the real Mail behaves. It shows the branches of `attemptSteps`, which
/// is what the live checks could not reach on demand.
final class DirectDraftPathOutcomeTests: XCTestCase {
    private var store: FixtureDraftStore!
    private var originalMailRoot: String?

    override func setUpWithError() throws {
        store = try FixtureDraftStore()
        originalMailRoot = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = store.mailRoot.path
        // Nothing below may reach the real Mail folder; a run with the override lost must not start.
        guard EnvelopeIndexReader.mailStoragePath == store.mailRoot.path else {
            throw NSError(domain: "DirectDraftPathOutcomeTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "the mail root override did not take effect"])
        }
    }

    override func tearDown() {
        EnvelopeIndexReader.mailStoragePathOverride = originalMailRoot
        store.remove()
        store = nil
    }

    private func path(_ mail: FakeDirectDraftMail) throws -> DirectDraftPath {
        var path = DirectDraftPath(
            controller: mail,
            reader: try EnvelopeIndexReader(databasePath: store.databasePath,
                                            accountMapping: [FixtureDraftStore.account: FixtureDraftStore.sender]),
            enabled: true, databasePath: store.databasePath, mailInfoPlist: store.mailInfoPlist.path)
        path.macOSMajorVersion = 27
        path.accountUUIDs = { _ in [FixtureDraftStore.account] }
        path.accountSignatureIDs = { _ in [] }
        return path
    }

    private static let steps = ["enter", "eligibility", "version_gate", "drafts_resolved", "writer_opened",
                                "inserted", "trigger_spawn"]

    /// Runs one `create_draft` through the same entry the server uses, with a timing CSV, and
    /// returns the result and the `direct` rows (label, outcome). `onGUI` runs inside the GUI path.
    private func run(_ path: DirectDraftPath, onGUI: @escaping () throws -> Void = {}) async throws
        -> (text: String, gui: Int, rows: [TimingRow]) {
        let csv = store.mailRoot.deletingLastPathComponent().appendingPathComponent("timing-\(UUID().uuidString).csv").path
        var guiCalls = 0
        let text = try await DirectDraftPath.createDraft(
            csvPath: csv, directEnabled: true,
            direct: {
                await path.attempt(to: ["to@example.invalid"], subject: "Fixture subject", body: "Fixture body",
                                   cc: nil, bcc: nil, attachments: nil, format: .plain,
                                   fromAddress: FixtureDraftStore.sender)
            },
            gui: { guiCalls += 1; try onGUI(); return "GUI" })
        return (text, guiCalls, try TimingRow.read(csv))
    }

    func testUploadConfirmedReportsCreatedAndEveryStepInOrder() async throws {
        let mail = FakeDirectDraftMail { rowId in try self.store.markUploaded(rowId) }
        let (text, gui, rows) = try await run(path(mail))
        XCTAssertEqual(gui, 0, "a created draft must not also go down the GUI path")
        XCTAssertTrue(text.hasPrefix("Draft created successfully"), text)
        XCTAssertTrue(text.contains("uploaded"), text)
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["trigger_sent", "uploaded", "read_ensured", "returned"])
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["created"])
        XCTAssertEqual(mail.triggers, 1)
        XCTAssertEqual(mail.markReads, 0, "the row already reads 1: no repair")
        XCTAssertEqual(try store.count("messages", where: "subject = (SELECT ROWID FROM subjects WHERE subject = 'Fixture subject')"), 1)
    }

    /// The upload request succeeded and Mail never confirmed it. The result must say so, and the
    /// path must not fall back (rule items 3 and 6).
    func testNoConfirmationWithinTheDeadlineReportsPendingAndDoesNotFallBack() async throws {
        let mail = FakeDirectDraftMail { _ in }
        var direct = try path(mail)
        direct.uploadDeadline = 0.3
        let (text, gui, rows) = try await run(direct)
        XCTAssertEqual(gui, 0)
        XCTAssertTrue(text.contains("upload pending"), text)
        XCTAssertTrue(text.contains("not confirmed"), text)
        XCTAssertFalse(text.contains("uploaded "), text)
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["trigger_sent", "returned"])
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["created:upload_pending"])
    }

    /// Rule item 2: a failed upload request is rolled back, and only then is the GUI path run.
    func testFailedTriggerRollsBackThenFallsBack() async throws {
        let before = try store.rowCounts()
        let mail = FakeDirectDraftMail { _ in throw MailError.scriptFailed(message: "fixture: Mail did not answer", code: -1) }
        let (text, gui, rows) = try await run(path(mail), onGUI: {
            // Inside the GUI path, so a rollback that ran after it would fail here.
            XCTAssertEqual(try self.store.rowCounts(), before, "the rows the rollback owns are gone before the GUI path starts")
            XCTAssertEqual(self.store.emlxFiles(), [], "so is the message file")
        })
        XCTAssertEqual(gui, 1, "the GUI path runs once")
        XCTAssertTrue(text.hasPrefix("GUI"), text)
        XCTAssertTrue(text.contains("experimental direct-write not used"), text)
        XCTAssertTrue(text.contains("the write was rolled back"), text)
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["fell_back:trigger"])
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["returned"])
    }

    /// Rule item 3: the trigger reported an error, but Mail already has the draft. Falling back
    /// would make a second draft, so the rollback is refused and the result is created.
    func testFailedTriggerAfterMailUploadedIsCreatedAndDoesNotFallBack() async throws {
        let mail = FakeDirectDraftMail { rowId in
            try self.store.addServerRow(rowId)
            throw MailError.scriptFailed(message: "fixture: timed out after the upload started", code: -1)
        }
        let (text, gui, rows) = try await run(path(mail))
        XCTAssertEqual(gui, 0, "a second draft is the failure this branch exists to prevent")
        XCTAssertTrue(text.contains("Mail had already uploaded the draft"), text)
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["created"])
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["returned"])
        XCTAssertEqual(store.emlxFiles().count, 1, "the draft stays")
    }

    /// Rule item 6: the rollback failed for another reason, so nothing is known about the upload.
    func testFailedTriggerThatCannotBeRolledBackIsPendingNotUploaded() async throws {
        let mail = FakeDirectDraftMail { _ in
            try self.store.exec("ALTER TABLE action_messages RENAME TO action_messages_away")
            throw MailError.scriptFailed(message: "fixture: Mail did not answer", code: -1)
        }
        let (text, gui, rows) = try await run(path(mail))
        XCTAssertEqual(gui, 0)
        XCTAssertTrue(text.contains("could not be reversed"), text)
        XCTAssertTrue(text.contains("not confirmed"), text)
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["created:upload_pending"])
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["returned"])
    }

    /// Rule item 7: after a confirmed upload the local copy is read, and repaired if it is unread.
    func testUploadedButUnreadIsRepairedAndConfirmed() async throws {
        let mail = FakeDirectDraftMail(onMarkRead: { rowId in try self.store.setRead(rowId, true) }) { rowId in
            try self.store.setRead(rowId, false)
            try self.store.markUploaded(rowId)
        }
        let (text, _, rows) = try await run(path(mail))
        XCTAssertEqual(mail.markReads, 1)
        XCTAssertFalse(text.contains("[note:"), text)
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["trigger_sent", "uploaded", "read_ensured", "returned"])
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["created"])
    }

    /// #492, evasion 3: a `Task` declared inside `DirectDraftPath` would turn every sleep into nothing,
    /// and the guard tests still read the same text. Mail takes a moment to apply the repair, so looks
    /// that do not wait use up their tries first.
    func testTheReadRepairGivesMailTimeBetweenItsLooks() async throws {
        let mail = FakeDirectDraftMail(onMarkRead: { rowId in
            let store = self.store!
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { try? store.setRead(rowId, true) }
        }) { rowId in
            try self.store.setRead(rowId, false)
            try self.store.markUploaded(rowId)
        }
        let (text, _, rows) = try await run(path(mail))
        XCTAssertFalse(text.contains("[note:"), text)
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["trigger_sent", "uploaded", "read_ensured", "returned"])
    }

    func testUploadedAndStillUnreadSaysSoAndIsNotReadEnsured() async throws {
        let mail = FakeDirectDraftMail { rowId in
            try self.store.setRead(rowId, false)
            try self.store.markUploaded(rowId)
        }
        let (text, _, rows) = try await run(path(mail))
        XCTAssertEqual(mail.markReads, 1)
        XCTAssertTrue(text.contains(DirectDraftPath.ReadOutcome.stillUnread.note), text)
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["trigger_sent", "uploaded", "returned"])
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["created"])
    }

    /// The gates still run in front of the write: a wrong host leaves the store untouched.
    func testAnOSOutsideTheVerifiedRangeWritesNothing() async throws {
        let before = try store.rowCounts()
        let mail = FakeDirectDraftMail { _ in XCTFail("no trigger without a write") }
        var direct = try path(mail)
        direct.macOSMajorVersion = 26
        let outcome = await direct.attempt(to: ["to@example.invalid"], subject: "S", body: "B", cc: nil, bcc: nil,
                                           attachments: nil, format: .plain, fromAddress: FixtureDraftStore.sender)
        XCTAssertEqual(outcome, .notAttempted(.version))
        XCTAssertEqual(try store.rowCounts(), before)
        XCTAssertEqual(mail.triggers, 0)
    }

    func testAnAccountWithASignatureWritesNothing() async throws {
        let before = try store.rowCounts()
        let mail = FakeDirectDraftMail { _ in XCTFail("no trigger without a write") }
        var direct = try path(mail)
        direct.accountSignatureIDs = { _ in ["signature-1"] }
        let outcome = await direct.attempt(to: ["to@example.invalid"], subject: "S", body: "B", cc: nil, bcc: nil,
                                           attachments: nil, format: .plain, fromAddress: FixtureDraftStore.sender)
        XCTAssertEqual(outcome, .notAttempted(.accountSignature))
        XCTAssertEqual(try store.rowCounts(), before)
    }

    func testDriftInTheStoreSchemaWritesNothing() async throws {
        try store.exec("ALTER TABLE messages ADD COLUMN unexpected INTEGER")
        let mail = FakeDirectDraftMail { _ in XCTFail("no trigger without a write") }
        let outcome = await (try path(mail)).attempt(to: ["to@example.invalid"], subject: "S", body: "B", cc: nil, bcc: nil,
                                                     attachments: nil, format: .plain, fromAddress: FixtureDraftStore.sender)
        guard case .notAttempted(.schemaDrift) = outcome else { return XCTFail("expected schema drift, got \(outcome)") }
    }

    // MARK: - A failed read of the upload state (#630)

    /// A remote id with the queued action unreadable: the second signal was never observed, so
    /// reporting uploaded here would claim what nobody saw (rule item 6). The path must end as
    /// pending and must not fall back (rule item 3).
    func testAFailedActionReadEndsAsPendingNotUploaded() async throws {
        let mail = FakeDirectDraftMail { rowId in
            try self.store.setRemoteId(rowId)
            try self.store.hideQueuedActions()
        }
        var direct = try path(mail)
        direct.uploadDeadline = 0.3
        let (text, gui, rows) = try await run(direct)
        XCTAssertEqual(gui, 0, "the upload request succeeded: no GUI path")
        XCTAssertTrue(text.contains("upload pending"), text)
        XCTAssertTrue(text.contains("not confirmed"), text)
        XCTAssertFalse(text.contains("uploaded "), text)
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["trigger_sent", "returned"])
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["created:upload_pending"])
    }

    /// A failure that clears inside the deadline is not a verdict: the loop keeps looking, and
    /// the upload it then observes is reported, with the read repair after it (rule item 7). It
    /// must not be reported before the read recovers: that is the failed read counting as "none".
    func testAnActionReadThatRecoversStillConfirmsTheUpload() async throws {
        let store = try XCTUnwrap(self.store)
        let recovery = RecoveryTask()
        let mail = FakeDirectDraftMail { rowId in
            try store.setRemoteId(rowId)
            try store.hideQueuedActions()
            recovery.task = Task.detached {
                try await Task.sleep(nanoseconds: 300_000_000)
                try store.showQueuedActions()
                try store.markUploaded(rowId)
            }
        }
        var direct = try path(mail)
        direct.uploadDeadline = 5
        let started = Date()
        let (text, gui, rows) = try await run(direct)
        let elapsed = Date().timeIntervalSince(started)
        try await recovery.task?.value
        XCTAssertGreaterThanOrEqual(elapsed, 0.3, "confirmed before the read recovered")
        XCTAssertEqual(gui, 0)
        XCTAssertTrue(text.contains("uploaded"), text)
        XCTAssertEqual(rows.direct.map { $0.label }, Self.steps + ["trigger_sent", "uploaded", "read_ensured", "returned"])
        XCTAssertEqual(Set(rows.direct.map { $0.outcome }), ["created"])
    }

    /// The fixture's own message with a remote id, and the writer the path would use.
    private func writerFacingUpload(actionRowId: Int64) throws -> (DraftStoreWriter, DraftStoreWriter.Inserted) {
        try store.setRemoteId(1)
        return (try DraftStoreWriter(databasePath: store.databasePath),
                DraftStoreWriter.Inserted(messageRowId: 1, conversationId: 0, globalDataRowId: 0,
                                          actionRowId: actionRowId, messageIdHash: 0, emlxPath: ""))
    }

    /// The other side of the fix: a read that worked and found no row still means not queued.
    func testAnActionReadThatFindsNoRowIsNotQueued() throws {
        let (writer, inserted) = try writerFacingUpload(actionRowId: 999)
        let state = writer.uploadState(inserted)
        XCTAssertEqual(state.remoteId, 4242)
        XCTAssertFalse(state.actionQueued)
    }

    func testAFailedActionReadCountsAsQueuedAndNamesTheCause() async throws {
        let (writer, inserted) = try writerFacingUpload(actionRowId: 999)
        try store.hideQueuedActions()
        var state: (remoteId: Int64?, actionQueued: Bool)?
        let log = try await capturingStderr { state = writer.uploadState(inserted) }
        XCTAssertEqual(state?.remoteId, 4242)
        XCTAssertEqual(state?.actionQueued, true)
        XCTAssertTrue(log.contains("local_message_actions read failed"), log)
    }

    func testAFailedRemoteIdReadIsUnknownAndNamesTheCause() async throws {
        try store.exec("INSERT INTO local_message_actions (ROWID) VALUES (7)")
        let (writer, inserted) = try writerFacingUpload(actionRowId: 7)
        try store.exec("ALTER TABLE messages RENAME TO messages_hidden")
        var state: (remoteId: Int64?, actionQueued: Bool)?
        let log = try await capturingStderr { state = writer.uploadState(inserted) }
        XCTAssertNotNil(state)
        XCTAssertNil(state?.remoteId)
        XCTAssertEqual(state?.actionQueued, true)
        XCTAssertTrue(log.contains("messages.remote_id read failed"), log)
    }

    // spec-example: message-composition / a missing messages table is reported on stderr
    /// #653: a failed read of the read flag still means "cannot tell", and now says why.
    func testAFailedReadFlagReadNamesItsCause() async throws {
        let (writer, inserted) = try writerFacingUpload(actionRowId: 999)
        try store.exec("ALTER TABLE messages RENAME TO messages_hidden")
        var flag: Bool?? = .none
        let log = try await capturingStderr { flag = .some(writer.readFlag(inserted)) }
        XCTAssertEqual(flag, .some(nil), "a failed read answers cannot tell")
        XCTAssertTrue(log.contains("messages.read read failed"), log)
    }

    // spec-example: message-composition / a deleted draft row reads as cannot tell without a log line
    /// #653, the other side: a read that works and finds no row is not a failed read.
    func testAReadFlagRowThatIsGoneLogsNothing() async throws {
        let writer = try DraftStoreWriter(databasePath: store.databasePath)
        let gone = DraftStoreWriter.Inserted(messageRowId: 999, conversationId: 0, globalDataRowId: 0,
                                             actionRowId: 999, messageIdHash: 0, emlxPath: "")
        var flag: Bool?? = .none
        let log = try await capturingStderr { flag = .some(writer.readFlag(gone)) }
        XCTAssertEqual(flag, .some(nil), "no row answers cannot tell")
        XCTAssertEqual(log, "", "a row that is gone is not a failed read")
    }

}

/// The background work of a Mail stand-in, kept so a test can await it and see it fail.
final class RecoveryTask: @unchecked Sendable {
    var task: Task<Void, Error>?
}

/// One `direct` row of a timing CSV.
struct TimingRow {
    let path: String
    let label: String
    let outcome: String

    static func read(_ csv: String) throws -> [TimingRow] {
        let lines = try String(contentsOfFile: csv, encoding: .utf8).split(separator: "\n").map(String.init)
        let header = try XCTUnwrap(lines.first).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let segment = try XCTUnwrap(header.firstIndex(of: "path"))
        let label = try XCTUnwrap(header.firstIndex(of: "step"))
        let outcome = try XCTUnwrap(header.firstIndex(of: "outcome"))
        return lines.dropFirst().map { line in
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return TimingRow(path: cells[segment], label: cells[label], outcome: cells[outcome])
        }
    }
}

extension Array where Element == TimingRow {
    var direct: [TimingRow] { filter { $0.path == ComposeTiming.directPath } }
}

/// Plays Mail for `DirectDraftPath`: confirms the Drafts mailbox, and runs a closure where the real
/// one would toggle the draft's read status.
final class FakeDirectDraftMail: DirectDraftMailControl, @unchecked Sendable {
    private let lock = NSLock()
    private var triggerCount = 0, markReadCount = 0
    private let onTrigger: @Sendable (Int64) throws -> Void
    private let onMarkRead: @Sendable (Int64) throws -> Void

    init(onMarkRead: @escaping @Sendable (Int64) throws -> Void = { _ in },
         onTrigger: @escaping @Sendable (Int64) throws -> Void) {
        self.onTrigger = onTrigger
        self.onMarkRead = onMarkRead
    }

    var triggers: Int { lock.lock(); defer { lock.unlock() }; return triggerCount }
    var markReads: Int { lock.lock(); defer { lock.unlock() }; return markReadCount }

    func getSpecialMailboxes(accountId: String?, accountName: String?) async throws -> [String: Any] {
        ["drafts": "Drafts"]
    }

    func confirmSpecialMailboxPaths(accountId: String, candidates: [SpecialMailboxPathCandidate]) async throws -> SpecialMailboxPathProof {
        SpecialMailboxPathProof(version: 1, count: candidates.count, results: candidates.indices.map {
            SpecialMailboxPathProof.Result(index: $0, available: true, matches: true)
        })
    }

    func triggerDirectDraftUpload(rowId: Int64, timing: Bool) async throws -> String {
        lock.lock(); triggerCount += 1; lock.unlock()
        try onTrigger(rowId)
        return "toggled"
    }

    func markDirectDraftRead(rowId: Int64) async throws -> String {
        lock.lock(); markReadCount += 1; lock.unlock()
        try onMarkRead(rowId)
        return "read"
    }
}

/// A throwaway Envelope Index with the tables and columns `DraftStoreWriter` verifies, one IMAP
/// Drafts mailbox, and one existing message from the sender. Never a copy of the real store.
final class FixtureDraftStore: @unchecked Sendable {
    static let account = "11111111-2222-4333-8444-555555555555"
    static let sender = "me@example.invalid"

    let root: URL
    let databasePath: String
    let mailRoot: URL
    let mailInfoPlist: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("direct-draft-\(UUID().uuidString)")
        mailRoot = root.appendingPathComponent("Mail")
        databasePath = root.appendingPathComponent("Envelope Index").path
        mailInfoPlist = root.appendingPathComponent("Info.plist")
        try FileManager.default.createDirectory(
            at: mailRoot.appendingPathComponent("\(Self.account)/Drafts.mbox/5FCC6F13-2CE3-48B1-907D-686244C0229A/Data"),
            withIntermediateDirectories: true)
        try (["CFBundleShortVersionString": "16.0", "CFBundleVersion": "3826"] as NSDictionary)
            .write(to: mailInfoPlist)
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
            INSERT INTO addresses (ROWID, address, comment) VALUES (1, '\(Self.sender)', 'Fixture Sender');
            INSERT INTO messages (message_id, sender, subject, mailbox, read) VALUES (1, 1, 0, 1, 1);
            """)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func exec(_ sql: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(databasePath, &db) == SQLITE_OK else {
            throw NSError(domain: "FixtureDraftStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        sqlite3_busy_timeout(db, 5000)
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let why = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw NSError(domain: "FixtureDraftStore", code: 2, userInfo: [NSLocalizedDescriptionKey: why])
        }
    }

    func count(_ table: String, where condition: String = "1") throws -> Int {
        var db: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table) WHERE \(condition)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "FixtureDraftStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "count failed for \(table)"])
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// The tables `DraftStoreWriter.rollback` restores. `addresses`, `subjects`, `message_global_data`
    /// and the `WriteTransactionGeneration` bump are not here: the rollback leaves them (#628).
    func rowCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in ["messages", "conversations", "conversation_id_message_id", "recipients",
                      "searchable_messages", "local_message_actions", "action_messages"] {
            counts[table] = try count(table)
        }
        return counts
    }

    func emlxFiles() -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: mailRoot.path)
        return (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".emlx") }
    }

    /// What Mail's upload leaves behind: a remote id, and the queued action gone.
    func markUploaded(_ rowId: Int64) throws {
        try exec("""
            UPDATE messages SET remote_id = 4242 WHERE ROWID = \(rowId);
            DELETE FROM local_message_actions WHERE ROWID = (SELECT action FROM action_messages WHERE destination_message = \(rowId));
            """)
    }

    /// A remote id alone, as when Mail set it and the action could not be read.
    func setRemoteId(_ rowId: Int64) throws {
        try exec("UPDATE messages SET remote_id = 4242 WHERE ROWID = \(rowId)")
    }

    /// Makes every read of the queued actions fail, the way a failing store would.
    func hideQueuedActions() throws {
        try exec("ALTER TABLE local_message_actions RENAME TO local_message_actions_hidden")
    }

    func showQueuedActions() throws {
        try exec("ALTER TABLE local_message_actions_hidden RENAME TO local_message_actions")
    }

    func addServerRow(_ rowId: Int64) throws {
        try exec("INSERT INTO server_messages (message, mailbox) VALUES (\(rowId), 1)")
    }

    func setRead(_ rowId: Int64, _ read: Bool) throws {
        try exec("UPDATE messages SET read = \(read ? 1 : 0) WHERE ROWID = \(rowId)")
    }
}
