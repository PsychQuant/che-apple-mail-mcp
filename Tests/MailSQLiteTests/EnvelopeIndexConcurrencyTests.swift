import XCTest
import SQLite3
@testable import MailSQLite

/// #536 — one `EnvelopeIndexReader` owns one `sqlite3*`, and the server hands
/// that reader to every request handler. Handlers run concurrently on the
/// cooperative pool, so two overlapping read tools used the same connection at
/// the same time. The connection was opened `SQLITE_OPEN_NOMUTEX`, which is
/// only valid when a connection is used by one thread at a time; the result is
/// undefined behaviour (crashes in synthetic runs, a CPU-bound livelock in the
/// field).
///
/// The fix serializes the connection (`SQLITE_OPEN_FULLMUTEX`) and gives it a
/// busy timeout. These tests pin both, and add a stress test that drives the
/// shared reader from many threads at once.
///
/// All data here is synthetic; no test reads `~/Library/Mail`.
final class EnvelopeIndexConcurrencyTests: XCTestCase {

    /// Cross-thread "stop" signal for the schema-churn thread.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    // MARK: - fixture

    private static let accountCount = 8
    private static let mailboxesPerAccount = 50
    private static let messageCount = 24_000

    /// UUID-shaped placeholder for account `index`.
    private static func accountUUID(_ index: Int) -> String { "ACCT-\(index)" }
    private static func accountName(_ index: Int) -> String { "Account \(index)" }

    private static let accountMapping: [String: String] = Dictionary(
        uniqueKeysWithValues: (0..<accountCount).map { (accountUUID($0), accountName($0)) })

    private func makeTempDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "EnvelopeIndexConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        return dir
    }

    /// Empty SQLite file; enough for `EnvelopeIndexReader.init`.
    private func makeEmptyDB() throws -> String {
        let path = try makeTempDirectory().appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "EnvelopeIndexConcurrencyTests", code: 1)
        }
        sqlite3_close(db)
        return path
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw NSError(domain: "EnvelopeIndexConcurrencyTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// WAL-mode Envelope Index with 8 accounts x 50 mailboxes and 24,000
    /// messages. Every third subject contains "plaud" so the search queries
    /// match thousands of rows and run long enough to overlap.
    private func makeFixtureDB() throws -> String {
        let path = try makeTempDirectory().appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "EnvelopeIndexConcurrencyTests", code: 3)
        }
        defer { sqlite3_close(db) }

        try exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER DEFAULT 0, unread_count INTEGER DEFAULT 0);
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER, date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0);
            CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
            BEGIN;
            """)

        let mailboxTotal = Self.accountCount * Self.mailboxesPerAccount
        for index in 0..<mailboxTotal {
            let account = index % Self.accountCount
            try exec(db, """
                INSERT INTO mailboxes (ROWID, url, total_count, unread_count)
                VALUES (\(index + 1), 'imap://\(Self.accountUUID(account))/Box\(index)', \(index), \(index % 7));
                """)
        }
        for index in 0..<50 {
            try exec(db, "INSERT INTO addresses VALUES (\(index + 1), 'person\(index)@example.invalid', 'Person \(index)');")
        }
        for index in 0..<Self.messageCount {
            let subject = index % 3 == 0 ? "report \(index) plaud" : "report \(index) other"
            try exec(db, "INSERT INTO subjects VALUES (\(index + 1), '\(subject)');")
            try exec(db, """
                INSERT INTO messages (ROWID, subject, sender, mailbox, date_received)
                VALUES (\(index + 1), \(index + 1), \(index % 50 + 1), \(index % mailboxTotal + 1), \(1_000_000 + index));
                """)
            if index % 5 == 0 {
                try exec(db, "INSERT INTO recipients (message, address, type, position) VALUES (\(index + 1), \(index % 50 + 1), 0, 0);")
            }
        }
        try exec(db, "COMMIT;")
        return path
    }

    // MARK: - the call mix

    /// One tool-shaped read. Each returns a signature string so the results of
    /// a concurrent call can be compared with the single-threaded baseline.
    private enum Call: CaseIterable {
        case listMailboxes, searchPage, searchSummaryPage, searchIds, searchCount, unreadCount

        func signature(_ reader: EnvelopeIndexReader, variant: Int) throws -> String {
            let account = variant % EnvelopeIndexConcurrencyTests.accountCount
            let params = SearchParameters(
                query: "plaud", field: .subject,
                accountName: EnvelopeIndexConcurrencyTests.accountName(account), limit: 40)
            switch self {
            case .listMailboxes:
                let boxes = try reader.listMailboxes(accountId: EnvelopeIndexConcurrencyTests.accountUUID(account))
                return boxes.compactMap { $0["name"] as? String }.sorted().joined(separator: ",")
            case .searchPage:
                let page = try reader.searchPage(params)
                return page.results.map { String($0.id) }.joined(separator: ",") + "|\(page.truncated)"
            case .searchSummaryPage:
                let page = try reader.searchSummaryPage(params)
                return page.results.map { String($0.id) }.joined(separator: ",") + "|\(page.truncated)"
            case .searchIds:
                let page = try reader.searchIds(params)
                return page.ids.map(String.init).joined(separator: ",") + "|\(page.truncated)"
            case .searchCount:
                return String(try reader.searchCount(params))
            case .unreadCount:
                return String(try reader.getUnreadCount(accountName: EnvelopeIndexConcurrencyTests.accountName(account)))
            }
        }
    }

    private struct Job: Hashable {
        let call: Call
        let variant: Int
    }

    private var allJobs: [Job] {
        Call.allCases.flatMap { call in
            (0..<Self.accountCount).map { Job(call: call, variant: $0) }
        }
    }

    /// Single-threaded expected result for every (call, variant) pair.
    private func baselines(_ reader: EnvelopeIndexReader) throws -> [Job: String] {
        var result: [Job: String] = [:]
        for job in allJobs {
            result[job] = try job.call.signature(reader, variant: job.variant)
        }
        return result
    }

    /// Drive `reader` from `workers` threads at once. Failures are collected
    /// and returned; nothing asserts on a worker thread.
    private func runConcurrently(_ reader: EnvelopeIndexReader, expected: [Job: String],
                                 workers: Int, rounds: Int) -> [String] {
        let jobs = allJobs
        let lock = NSLock()
        var failures: [String] = []
        func record(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            if failures.count < 20 { failures.append(message) }
        }
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for round in 0..<rounds {
                let job = jobs[(worker * 7 + round) % jobs.count]
                do {
                    let got = try job.call.signature(reader, variant: job.variant)
                    if got != expected[job] {
                        record("worker \(worker) round \(round) \(job.call) variant \(job.variant): result differs from the single-threaded baseline")
                    }
                } catch {
                    record("worker \(worker) round \(round) \(job.call) variant \(job.variant): \(error)")
                }
            }
        }
        return failures
    }

    // MARK: - T1 / T2: the connection configuration (deterministic)

    /// SQLite must guard the shared connection itself. Under NOMUTEX
    /// `sqlite3_db_mutex` is NULL, so two handlers can step the same
    /// connection at once.
    func testConnectionIsSerialized() throws {
        try XCTSkipIf(sqlite3_threadsafe() == 0, "SQLite was built without thread support")
        let reader = try EnvelopeIndexReader(databasePath: try makeEmptyDB(), accountMapping: [:])
        XCTAssertTrue(reader.isSerialized,
            "the reader's single connection is shared by concurrent request handlers, so it must be opened SQLITE_OPEN_FULLMUTEX (#536)")
    }

    /// A reader that meets a locked database should wait, not fail at once.
    func testBusyTimeoutIsConfigured() throws {
        let reader = try EnvelopeIndexReader(databasePath: try makeEmptyDB(), accountMapping: [:])
        XCTAssertEqual(reader.busyTimeoutMilliseconds, EnvelopeIndexReader.busyTimeoutMilliseconds,
            "the connection should carry the reader's busy timeout (#536)")
        XCTAssertGreaterThan(EnvelopeIndexReader.busyTimeoutMilliseconds, 0)
    }

    // MARK: - T3 / T4: concurrent reads (stress)

    /// 12 threads hammer one reader with the mix of reads the tools issue.
    /// Every result must equal the single-threaded baseline. With the
    /// connection unserialized this crashed the process in synthetic runs.
    func testConcurrentMixedReadsCompleteWithCorrectResults() throws {
        let reader = try EnvelopeIndexReader(databasePath: try makeFixtureDB(),
                                             accountMapping: Self.accountMapping)
        let expected = try baselines(reader)
        XCTAssertFalse(expected.values.contains(""), "fixture must produce non-empty baselines")

        let failures = runConcurrently(reader, expected: expected, workers: 12, rounds: 60)
        XCTAssertEqual(failures, [], "concurrent reads must all complete with the baseline results")
    }

    /// Same, while another connection keeps changing the schema (what a Mail
    /// write that bumps the schema cookie looks like to a reader). The #536
    /// diagnosis showed the crash does not need this; it is kept because it was
    /// the original suspicion.
    func testConcurrentReadsSurviveSchemaChurn() throws {
        let path = try makeFixtureDB()
        let reader = try EnvelopeIndexReader(databasePath: path, accountMapping: Self.accountMapping)
        let expected = try baselines(reader)

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil), SQLITE_OK)
        defer { sqlite3_close(writer) }
        sqlite3_busy_timeout(writer, 2000)

        let stopFlag = StopFlag()
        let churn = Thread {
            while !stopFlag.isSet {
                sqlite3_exec(writer, "CREATE TABLE IF NOT EXISTS churn (x); DROP TABLE churn;", nil, nil, nil)
                usleep(20_000)
            }
        }
        churn.start()

        let failures = runConcurrently(reader, expected: expected, workers: 12, rounds: 40)

        stopFlag.set()
        // Let the churn thread finish its current statement before the writer
        // handle is closed by the deferred block.
        usleep(100_000)
        XCTAssertEqual(failures, [], "concurrent reads must survive schema changes made by another connection")
    }
}
