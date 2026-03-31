import XCTest
import SQLite3
@testable import MailSQLite

final class EmlxPathTests: XCTestCase {

    // MARK: - Hash Directory Calculation

    func testHashDirectoryForLargeRowId() {
        // ROWID 267597: ones=7, tens=9, hundreds=5
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 267597), "7/9/5")
    }

    func testHashDirectoryForTwoDigitRowId() {
        // ROWID 42: ones=2, tens=4, hundreds=0
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 42), "2/4/0")
    }

    func testHashDirectoryForSingleDigitRowId() {
        // ROWID 5: ones=5, tens=0, hundreds=0
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 5), "5/0/0")
    }

    func testHashDirectoryForZero() {
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 0), "0/0/0")
    }

    func testHashDirectoryForExactlyThreeDigits() {
        // ROWID 123: ones=3, tens=2, hundreds=1
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 123), "3/2/1")
    }

    func testHashDirectoryForRoundNumber() {
        // ROWID 1000: ones=0, tens=0, hundreds=0
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 1000), "0/0/0")
    }

    func testHashDirectoryForMaxDigits() {
        // ROWID 999: ones=9, tens=9, hundreds=9
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 999), "9/9/9")
    }

    // MARK: - resolveEmlxPath with Invalid Input

    func testResolveEmlxPathWithMalformedURL() {
        let result = EmlxParser.resolveEmlxPath(rowId: 1, mailboxURL: "not-a-valid-url")
        XCTAssertNil(result, "Should return nil for malformed URL")
    }

    func testResolveEmlxPathWithURLMissingPath() {
        let result = EmlxParser.resolveEmlxPath(rowId: 1, mailboxURL: "imap://some-uuid")
        XCTAssertNil(result, "Should return nil when URL has no mailbox path")
    }

    // MARK: - resolveEmlxPath with Real Data

    func testResolveEmlxPathForRealMessage() throws {
        let dbPath = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Envelope Index not available at \(dbPath)")
        }

        let reader = try EnvelopeIndexReader(databasePath: dbPath)

        // Search for a recent message to get a real ROWID and mailbox URL
        let params = SearchParameters(query: "", field: .any, limit: 1)
        let results = try reader.search(params)
        guard let first = results.first else {
            throw XCTSkip("No messages found in Envelope Index")
        }

        // We need the mailbox URL, which requires querying directly.
        // The SearchResult has mailboxPath but not the raw URL.
        // Use a simple query to get the raw URL for this ROWID.
        let url = try fetchMailboxURL(reader: reader, rowId: first.id, dbPath: dbPath)
        guard let mailboxURL = url else {
            throw XCTSkip("Could not retrieve mailbox URL for message \(first.id)")
        }

        let path = EmlxParser.resolveEmlxPath(rowId: first.id, mailboxURL: mailboxURL)
        // The file may or may not exist depending on Mail.app state,
        // but if it does, verify the path structure.
        if let path = path {
            XCTAssertTrue(path.contains("/Messages/\(first.id)."), "Path should contain Messages/<ROWID>")
            XCTAssertTrue(path.contains("/Data/"), "Path should contain Data directory")
            XCTAssertTrue(path.hasSuffix(".emlx"), "Path should end with .emlx")
        }
    }

    // MARK: - Private Helpers

    private func fetchMailboxURL(reader: EnvelopeIndexReader, rowId: Int, dbPath: String) throws -> String? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT mb.url FROM messages m JOIN mailboxes mb ON m.mailbox = mb.ROWID WHERE m.ROWID = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(rowId))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }
}
