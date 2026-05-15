import XCTest
@testable import MailSQLite

final class EnvelopeIndexReaderTests: XCTestCase {

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

    func testAccountUUIDs_unambiguous_returnsSingleUUID() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }
        let reader = try EnvelopeIndexReader(
            databasePath: path,
            accountMapping: ["UUID-A": "Alice"]
        )
        XCTAssertEqual(reader.accountUUIDs(forName: "Alice"), ["UUID-A"])
    }

    func testAccountUUIDs_collision_returnsAllUUIDs() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }
        let reader = try EnvelopeIndexReader(
            databasePath: path,
            accountMapping: [
                "UUID-A": "Same",
                "UUID-B": "Same",
                "UUID-C": "Other"
            ]
        )
        let collisionUUIDs = Set(reader.accountUUIDs(forName: "Same"))
        XCTAssertEqual(collisionUUIDs, Set(["UUID-A", "UUID-B"]),
                       "Collision case must surface BOTH UUIDs (callers detect via .count > 1)")
        XCTAssertEqual(reader.accountUUIDs(forName: "Other"), ["UUID-C"])
    }

    func testAccountUUIDs_unknown_returnsEmpty() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }
        let reader = try EnvelopeIndexReader(
            databasePath: path,
            accountMapping: ["UUID-A": "Alice"]
        )
        XCTAssertEqual(reader.accountUUIDs(forName: "Nobody"), [])
    }

    func testAccountUUIDs_reflectsUpdateAccountMapping() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }
        let reader = try EnvelopeIndexReader(
            databasePath: path,
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
