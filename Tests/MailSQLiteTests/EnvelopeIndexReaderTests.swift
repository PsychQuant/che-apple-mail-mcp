import XCTest
import SQLite3
@testable import MailSQLite

final class EnvelopeIndexReaderTests: XCTestCase {

    // MARK: - Hermetic Test Fixture (#106 verify follow-up)

    /// Create an empty SQLite file in a temp directory + register cleanup.
    /// Returns the path, which is suitable for `EnvelopeIndexReader(databasePath:)`
    /// init (read-only open succeeds on any valid SQLite file, including empty).
    ///
    /// Lets the reverse-lookup tests run hermetically — independent of whether
    /// the host machine has a real Apple Mail Envelope Index. The reader's
    /// init only needs the file to be a parseable SQLite database; downstream
    /// queries are never run (we only test the in-memory accountMap /
    /// reverseAccountMap pair).
    private func makeEmptyTestDB() throws -> String {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "EnvelopeIndexReaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fm.removeItem(at: tmpDir)
        }

        let dbPath = tmpDir.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            throw NSError(
                domain: "EnvelopeIndexReaderTests",
                code: Int(SQLITE_ERROR),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create empty test SQLite file at \(dbPath)"]
            )
        }
        sqlite3_close(db)
        return dbPath
    }

    // MARK: - Connection Management

    func testInitWithValidDatabasePath() throws {
        // Use the real Envelope Index if available, skip otherwise
        let path = try realEnvelopeIndexPathOrSkip()
        let reader = try EnvelopeIndexReader(databasePath: path)
        XCTAssertNotNil(reader)
    }

    func testInitWithNonexistentPathThrows() {
        XCTAssertThrowsError(try EnvelopeIndexReader(databasePath: "/nonexistent/path/db")) { error in
            guard let mailError = error as? MailSQLiteError else {
                XCTFail("Expected MailSQLiteError, got \(error)")
                return
            }
            if case .databaseNotAccessible(let msg) = mailError {
                XCTAssertTrue(msg.contains("Full Disk Access") || msg.contains("does not exist"),
                              "Error should mention access issue: \(msg)")
            } else {
                XCTFail("Expected .databaseNotAccessible, got \(mailError)")
            }
        }
    }

    /// #537 — `sqlite3_open_v2` succeeds on any file, because SQLite reads the
    /// file lazily. A reader that "opened" such a file would then be handed out
    /// as available while every query fails. Init must run a cheap query so that
    /// a non-database file is refused at open time, where the provider can retry.
    func testInitRejectsAFileThatIsNotADatabase() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "EnvelopeIndexReaderTests-notadb-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Envelope Index").path
        // Long enough to contain a full 100-byte header's worth of non-SQLite bytes.
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try EnvelopeIndexReader(databasePath: path, accountMapping: [:])) { error in
            guard case MailSQLiteError.databaseNotAccessible(let message)? = error as? MailSQLiteError else {
                return XCTFail("expected .databaseNotAccessible, got \(error)")
            }
            XCTAssertTrue(message.contains("Failed to read database"),
                          "the message should say the open worked but the first query did not; got: \(message)")
        }
    }

    /// The validation query must not turn a legitimately empty database into a
    /// failure (`SELECT 1 FROM sqlite_master` has no rows there, which is fine).
    func testInitAcceptsAnEmptyDatabase() throws {
        XCTAssertNoThrow(try EnvelopeIndexReader(databasePath: try makeEmptyTestDB(), accountMapping: [:]))
    }

    func testDefaultDatabasePathUsesV10() {
        let path = EnvelopeIndexReader.defaultDatabasePath
        XCTAssertTrue(path.contains("/V10/"), "Path should contain V10 segment")
        XCTAssertTrue(path.hasSuffix("Envelope Index"), "Path should end with 'Envelope Index'")
    }

    // MARK: - Account Mapping

    func testAccountNameWithMapping() throws {
        let path = try realEnvelopeIndexPathOrSkip()
        let reader = try EnvelopeIndexReader(
            databasePath: path,
            accountMapping: ["ABC-123": "My Gmail"]
        )
        XCTAssertEqual(reader.accountName(for: "ABC-123"), "My Gmail")
    }

    func testAccountNameFallsBackToUUID() throws {
        let path = try realEnvelopeIndexPathOrSkip()
        let reader = try EnvelopeIndexReader(databasePath: path)
        XCTAssertEqual(reader.accountName(for: "UNKNOWN-UUID"), "UNKNOWN-UUID")
    }

    func testScanAccountUUIDs() {
        let uuids = EnvelopeIndexReader.scanAccountUUIDs()
        // On a real system with Mail.app, there should be UUID directories
        for uuid in uuids {
            XCTAssertEqual(uuid.count, 36, "UUID should be 36 chars: \(uuid)")
        }
    }

    // MARK: - Account UUID Reverse Lookup (#106)
    //
    // Tests use a hermetic temp SQLite fixture (see `makeEmptyTestDB`)
    // instead of `EnvelopeIndexReader.defaultDatabasePath` + `XCTSkip` —
    // so CI environments without real Apple Mail data still run the verification.
    // Addresses Codex P3 follow-up from /idd-verify --pr 108 review.

    func testAccountUUIDs_unambiguous_returnsSingleUUID() throws {
        let reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: ["UUID-A": "Alice"]
        )
        XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), ["UUID-A"])
    }

    func testAccountUUIDs_collision_returnsAllUUIDs() throws {
        let reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: [
                "UUID-A": "Same",
                "UUID-B": "Same",
                "UUID-C": "Other"
            ]
        )
        let collisionList = reader.accountUUIDs(forName: "Same")
        // Count assertion first — catches duplicate-UUID regression that the
        // downstream Set comparison would silently swallow (Devil's Advocate
        // P3 finding from /idd-verify --pr 108: if impl ever returned
        // [UUID-A, UUID-A, UUID-B] the Set check would still pass).
        XCTAssertEqual(collisionList.count, 2,
                       "Collision result must contain exactly 2 UUIDs — no duplicates")
        XCTAssertEqual(Set(collisionList), Set(["UUID-A", "UUID-B"]),
                       "Collision case must surface BOTH UUIDs (callers detect via .count > 1)")
        XCTAssertEqual(reader.accountUUIDs(forName: "Other"), ["UUID-C"])
    }

    func testAccountUUIDs_unknown_returnsEmpty() throws {
        let reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: ["UUID-A": "Alice"]
        )
        XCTAssertEqual(reader.accountUUIDs(forName: "Nobody"), [])
    }

    func testAccountUUIDs_reflectsUpdateAccountMapping() throws {
        let reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: ["UUID-A": "Alice"]
        )
        XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), ["UUID-A"])
        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), [])

        // Replace mapping — reverse map MUST rebuild, not stay stale.
        // Regression-locks the "lazy var staleness" bug pattern flagged in #106 body.
        reader.updateAccountMapping(["UUID-Z": "Bob"])
        XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), [],
                       "After updateAccountMapping, old name 'Alice' must not resolve to any UUID")
        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), ["UUID-Z"])
    }

    // MARK: - Account mapping refresh (#554)

    /// Stands in for AccountsMap.plist: what the next read returns, and how
    /// many times it was read.
    private final class MappingSource {
        var mapping: [String: String]
        var reads = 0
        init(_ mapping: [String: String]) { self.mapping = mapping }
        func read() -> [String: String] { reads += 1; return mapping }
    }

    private final class FakeClock {
        var now: TimeInterval = 1_000
    }

    private func makeReader(initial: [String: String]?, source: MappingSource,
                            cooldown: TimeInterval = 5, clock: FakeClock = FakeClock()) throws -> EnvelopeIndexReader {
        try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: initial,
            accountMappingSource: { source.read() },
            mappingRefreshCooldown: cooldown,
            clock: { clock.now }
        )
    }

    func testAccountAddedAfterStartupResolvesByNameAndUUID() throws {
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeReader(initial: ["UUID-A": "Alice"], source: source)
        source.mapping = ["UUID-A": "Alice", "UUID-B": "Bob"]   // account added while the server runs

        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), ["UUID-B"])
        XCTAssertEqual(reader.accountName(for: "UUID-B"), "Bob")
        XCTAssertEqual(source.reads, 1, "one miss re-reads the mapping once")
    }

    func testUnknownUUIDRefreshesTheMapping() throws {
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeReader(initial: ["UUID-A": "Alice"], source: source)
        source.mapping = ["UUID-A": "Alice", "UUID-B": "Bob"]

        XCTAssertEqual(reader.accountName(for: "UUID-B"), "Bob")
        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), ["UUID-B"])
    }

    func testRenamedAccountResolvesUnderTheNewNameOnly() throws {
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeReader(initial: ["UUID-A": "Alice"], source: source)
        source.mapping = ["UUID-A": "Alicia"]

        XCTAssertEqual(reader.accountUUIDs(forName: "Alicia"), ["UUID-A"])
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alicia")
        XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), [],
                       "once the mapping is re-read, the old name no longer resolves")
    }

    func testHitsNeverReadTheSource() throws {
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeReader(initial: ["UUID-A": "Alice"], source: source)
        for _ in 0..<50 {
            XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), ["UUID-A"])
            XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alice")
        }
        XCTAssertEqual(source.reads, 0)
    }

    func testMissesWithinTheCooldownReadTheSourceOnce() throws {
        let clock = FakeClock()
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeReader(initial: ["UUID-A": "Alice"], source: source, cooldown: 5, clock: clock)

        for _ in 0..<20 { XCTAssertEqual(reader.accountUUIDs(forName: "Nobody"), []) }
        XCTAssertEqual(source.reads, 1, "a name that never resolves must not cause a read per call")

        clock.now += 4.9
        XCTAssertEqual(reader.accountName(for: "UUID-X"), "UUID-X")
        XCTAssertEqual(source.reads, 1)

        clock.now += 0.2
        source.mapping = ["UUID-A": "Alice", "UUID-B": "Bob"]
        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), ["UUID-B"], "after the cooldown a miss reads again")
        XCTAssertEqual(source.reads, 2)
    }

    func testMappingReadAtStartupStartsTheCooldown() throws {
        let clock = FakeClock()
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeReader(initial: nil, source: source, cooldown: 5, clock: clock)
        XCTAssertEqual(source.reads, 1, "no injected mapping: init reads the source")
        XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), ["UUID-A"])

        source.mapping = ["UUID-A": "Alice", "UUID-B": "Bob"]
        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), [], "the mapping read at init is still fresh")
        XCTAssertEqual(source.reads, 1)

        clock.now += 5
        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), ["UUID-B"])
        XCTAssertEqual(source.reads, 2)
    }

    func testAnUnreadableMappingKeepsTheAccountsAlreadyKnown() throws {
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeReader(initial: ["UUID-A": "Alice"], source: source)
        source.mapping = [:]   // what AccountMapper returns when the plist cannot be read

        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), [])
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), ["UUID-A"])
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alice")
    }

    func testAnInjectedMappingWithoutASourceIsNeverReplaced() throws {
        // Fixtures inject a mapping and must stay hermetic: a miss may not read
        // the user's AccountsMap.plist.
        let reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: ["UUID-A": "Alice"]
        )
        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), [])
        XCTAssertEqual(reader.accountName(for: "UUID-B"), "UUID-B")
        XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), ["UUID-A"])
    }

    func testConcurrentLookupsAndRefreshesStayConsistent() throws {
        let source = MappingSource(["UUID-A": "Alice"])
        let lock = NSLock()
        let reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: ["UUID-A": "Alice"],
            accountMappingSource: { lock.lock(); defer { lock.unlock() }; return source.read() },
            mappingRefreshCooldown: 0
        )
        source.mapping = ["UUID-A": "Alice", "UUID-B": "Bob"]
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            switch i % 4 {
            case 0: XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), ["UUID-A"])
            case 1: _ = reader.accountUUIDs(forName: "Nobody-\(i)")
            case 2: XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alice")
            default: reader.updateAccountMapping(["UUID-A": "Alice", "UUID-B": "Bob"])
            }
        }
        XCTAssertEqual(reader.accountUUIDs(forName: "Bob"), ["UUID-B"])
    }

    func testASourceThatCallsBackIntoTheReaderDoesNotDeadlock() throws {
        // The source is read outside the mapping lock (#554 verify), so a
        // source that looks something up on the same reader cannot deadlock.
        var reader: EnvelopeIndexReader?
        reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: ["UUID-A": "Alice"],
            accountMappingSource: {
                _ = reader?.accountName(for: "UUID-A")
                return ["UUID-A": "Alice", "UUID-B": "Bob"]
            },
            mappingRefreshCooldown: 60
        )
        let done = DispatchSemaphore(value: 0)
        var resolved: [String] = []
        DispatchQueue.global().async {
            resolved = reader?.accountUUIDs(forName: "Bob") ?? []
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "lookup deadlocked")
        XCTAssertEqual(resolved, ["UUID-B"])
    }

    func testARefreshDoesNotOverwriteAMappingInstalledWhileItRead() throws {
        var reader: EnvelopeIndexReader?
        reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: ["UUID-A": "Alice"],
            accountMappingSource: {
                // Another install lands while the source is being read.
                reader?.updateAccountMapping(["UUID-C": "Carol"])
                return ["UUID-A": "Alice", "UUID-B": "Bob"]
            },
            mappingRefreshCooldown: 60
        )
        XCTAssertEqual(reader?.accountUUIDs(forName: "Bob"), [])
        XCTAssertEqual(reader?.accountUUIDs(forName: "Carol"), ["UUID-C"],
                       "the newer mapping wins over the read that started before it")
    }

    func testNameScopedListMailboxesResolvesAnAccountAddedAfterStartup() throws {
        let path = try makeEmptyTestDB()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER, unread_count INTEGER);
            INSERT INTO mailboxes VALUES (1, 'imap://UUID-A/INBOX', 3, 1);
            INSERT INTO mailboxes VALUES (2, 'imap://UUID-B/INBOX', 5, 2);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try EnvelopeIndexReader(
            databasePath: path,
            accountMapping: ["UUID-A": "Alice"],
            accountMappingSource: { source.read() }
        )
        source.mapping = ["UUID-A": "Alice", "UUID-B": "Bob"]

        let mailboxes = try reader.listMailboxes(accountName: "Bob")
        XCTAssertEqual(mailboxes.count, 1)
        XCTAssertEqual(mailboxes.first?["account_name"] as? String, "Bob")
        XCTAssertEqual(mailboxes.first?["total_count"] as? Int, 5)
    }

    // MARK: - Mapping refresh on a hit (#615)

    /// Stands in for AccountsMap.plist's modification date.
    private final class StampSource {
        var stamp: Date? = Date(timeIntervalSince1970: 1_000)
        var reads = 0
        func read() -> Date? { reads += 1; return stamp }
    }

    private func makeStampedReader(_ source: MappingSource, stamp: StampSource, clock: FakeClock,
                                   cooldown: TimeInterval = 5) throws -> EnvelopeIndexReader {
        try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: source.mapping,
            accountMappingSource: { source.read() },
            accountMappingStamp: { stamp.read() },
            mappingRefreshCooldown: cooldown,
            clock: { clock.now }
        )
    }

    func testAHitPicksUpAChangedMappingAfterTheCooldown() throws {
        let clock = FakeClock(), stamp = StampSource()
        let source = MappingSource(["UUID-A": "alice@example.com"])
        let reader = try makeStampedReader(source, stamp: stamp, clock: clock)

        source.mapping = ["UUID-A": "alicia@example.com"]
        stamp.stamp = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "alice@example.com", "inside the cooldown")

        clock.now += 5
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "alicia@example.com", "a hit, with no miss to trigger it")
        XCTAssertEqual(reader.accountUUIDs(forName: "alice@example.com"), [], "the old email no longer resolves")
    }

    func testANameLookupThatHitsAlsoChecks() throws {
        let clock = FakeClock(), stamp = StampSource()
        let source = MappingSource(["UUID-A": "alice@example.com"])
        let reader = try makeStampedReader(source, stamp: stamp, clock: clock)

        // Another account took over the old email: without the check, the
        // old answer would send a name-scoped query to the wrong account.
        source.mapping = ["UUID-B": "alice@example.com"]
        stamp.stamp = Date(timeIntervalSince1970: 2_000)
        clock.now += 5
        XCTAssertEqual(reader.accountUUIDs(forName: "alice@example.com"), ["UUID-B"])
    }

    func testNoStatInsideTheCooldownAndNoReadWhileTheStampHolds() throws {
        let clock = FakeClock(), stamp = StampSource()
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeStampedReader(source, stamp: stamp, clock: clock)
        let afterInit = stamp.reads

        for _ in 0..<100 { _ = reader.accountName(for: "UUID-A") }
        XCTAssertEqual(stamp.reads, afterInit, "per-row lookups must not stat")

        clock.now += 5
        for _ in 0..<100 { _ = reader.accountName(for: "UUID-A") }
        XCTAssertEqual(stamp.reads, afterInit + 1, "one stat per interval")
        XCTAssertEqual(source.reads, 0, "an unchanged stamp reads nothing")
    }

    func testAMissStatsNoMoreThanAHit() throws {
        let clock = FakeClock(), stamp = StampSource()
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeStampedReader(source, stamp: stamp, clock: clock)
        let afterInit = stamp.reads

        clock.now += 5
        _ = reader.accountName(for: "UUID-B")
        XCTAssertEqual(source.reads, 1, "the miss read the source")
        XCTAssertEqual(stamp.reads, afterInit + 1, "one stat per interval, on a miss too")
    }

    func testAChangedStampWaitsOutTheSourceCooldownAfterAMissRead() throws {
        let clock = FakeClock(), stamp = StampSource()
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeStampedReader(source, stamp: stamp, clock: clock)

        clock.now += 5
        _ = reader.accountName(for: "UUID-A")     // the stamp check, at t=5
        clock.now += 1
        _ = reader.accountName(for: "UUID-B")     // a miss read, at t=6
        XCTAssertEqual(source.reads, 1)

        source.mapping = ["UUID-A": "Alicia"]
        stamp.stamp = Date(timeIntervalSince1970: 2_000)
        clock.now += 4
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alice", "t=10 is 4 s after the last read")
        XCTAssertEqual(source.reads, 1, "the source is read at most once per cooldown, whichever path asks")

        clock.now += 5
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alicia", "the stamp stayed unrecorded, so the check retries")
        XCTAssertEqual(source.reads, 2)
    }

    func testAnUnreadableStampChangesNothing() throws {
        let clock = FakeClock(), stamp = StampSource()
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeStampedReader(source, stamp: stamp, clock: clock)

        stamp.stamp = nil
        source.mapping = ["UUID-A": "Alicia"]
        clock.now += 5
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alice")
        XCTAssertEqual(source.reads, 0)
    }

    func testAChangedStampWithAnUnreadableMappingKeepsTheMappingAndTriesAgain() throws {
        let clock = FakeClock(), stamp = StampSource()
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeStampedReader(source, stamp: stamp, clock: clock)

        source.mapping = [:]
        stamp.stamp = Date(timeIntervalSince1970: 2_000)
        clock.now += 5
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alice", "an empty read forgets nothing")
        XCTAssertEqual(source.reads, 1)

        source.mapping = ["UUID-A": "Alicia"]
        clock.now += 5
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alicia", "the stamp is recorded only with a good read")
    }

    func testAChangeDuringTheReadIsPickedUpByTheNextCheck() throws {
        let clock = FakeClock(), stamp = StampSource()
        let source = MappingSource(["UUID-A": "Alice"])
        var hook: (() -> Void)?
        let reader = try EnvelopeIndexReader(
            databasePath: try makeEmptyTestDB(),
            accountMapping: source.mapping,
            accountMappingSource: { let mapping = source.read(); hook?(); return mapping },
            accountMappingStamp: { stamp.read() },
            clock: { clock.now }
        )
        source.mapping = ["UUID-A": "Alicia"]
        stamp.stamp = Date(timeIntervalSince1970: 2_000)
        hook = {
            hook = nil
            source.mapping = ["UUID-A": "Alina"]
            stamp.stamp = Date(timeIntervalSince1970: 3_000)
        }
        clock.now += 5
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alicia")
        clock.now += 5
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alina", "the stamp was taken before the read")
    }

    func testASourceWithoutAStampIsOnlyReadOnMisses() throws {
        let clock = FakeClock()
        let source = MappingSource(["UUID-A": "Alice"])
        let reader = try makeReader(initial: ["UUID-A": "Alice"], source: source, clock: clock)
        source.mapping = ["UUID-A": "Alicia"]
        clock.now += 60
        XCTAssertEqual(reader.accountName(for: "UUID-A"), "Alice")
        XCTAssertEqual(source.reads, 0)
    }

    func testAccountsMapStampReadsTheFilesDate() throws {
        let path = try makeEmptyTestDB()
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        XCTAssertEqual(AccountMapper.accountsMapModificationDate(path: path), date)
        XCTAssertNil(AccountMapper.accountsMapModificationDate(path: path + ".absent"))
    }
}
