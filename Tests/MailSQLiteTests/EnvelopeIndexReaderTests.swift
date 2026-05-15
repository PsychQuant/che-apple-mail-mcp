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
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available at \(path)")
        }
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

    func testDefaultDatabasePathUsesV10() {
        let path = EnvelopeIndexReader.defaultDatabasePath
        XCTAssertTrue(path.contains("/V10/"), "Path should contain V10 segment")
        XCTAssertTrue(path.hasSuffix("Envelope Index"), "Path should end with 'Envelope Index'")
    }

    // MARK: - Account Mapping

    func testAccountNameWithMapping() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }
        let reader = try EnvelopeIndexReader(
            databasePath: path,
            accountMapping: ["ABC-123": "My Gmail"]
        )
        XCTAssertEqual(reader.accountName(for: "ABC-123"), "My Gmail")
    }

    func testAccountNameFallsBackToUUID() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }
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
}
