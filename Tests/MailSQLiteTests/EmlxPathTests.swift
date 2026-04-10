import XCTest
import SQLite3
@testable import MailSQLite

final class EmlxPathTests: XCTestCase {

    // MARK: - Hash Directory Calculation

    func testHashDirectoryForLargeRowId() {
        // ROWID 262653: thousands=2, tenthousands=6, hundredthousands=2
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 262653), "2/6/2")
    }

    func testHashDirectoryForAnotherLargeRowId() {
        // ROWID 267943: thousands=7, tenthousands=6, hundredthousands=2
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 267943), "7/6/2")
    }

    func testHashDirectoryForSmallRowId() {
        // ROWID 42: all three digits are 0 (below thousands)
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 42), "0/0/0")
    }

    func testHashDirectoryForSingleDigitRowId() {
        // ROWID 5: below thousands → 0/0/0
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 5), "0/0/0")
    }

    func testHashDirectoryForZero() {
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 0), "0/0/0")
    }

    func testHashDirectoryForExactlyThreeDigits() {
        // ROWID 123: still below thousands → 0/0/0
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 123), "0/0/0")
    }

    func testHashDirectoryForExactlyOneThousand() {
        // ROWID 1000: thousands=1, tenthousands=0, hundredthousands=0
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 1000), "1/0/0")
    }

    func testHashDirectoryForLowerBoundOfSixDigits() {
        // ROWID 100000: thousands=0, tenthousands=0, hundredthousands=1
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 100000), "0/0/1")
    }

    func testHashDirectoryForMaxSixDigits() {
        // ROWID 999999: all three digits = 9
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 999999), "9/9/9")
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

    // MARK: - resolveEmlxPath with fake filesystem fixture

    /// Regression test for #9: hashDirectoryPath must match Apple Mail V10's
    /// actual on-disk layout, which hashes the ROWID by
    /// thousands/tenthousands/hundredthousands — not ones/tens/hundreds.
    ///
    /// Observed from real mailboxes:
    ///   ROWID 262653 → `…/Data/2/6/2/Messages/262653.emlx`
    ///   ROWID 266684 → `…/Data/6/6/2/Messages/266684.emlx`
    func testResolveEmlxPathFindsFileAtThousandsLevelHash() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "emlx-fixture-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: tmp) }

        let mailV10 = tmp.appendingPathComponent("Library/Mail/V10", isDirectory: true)
        let accountUUID = "ABCE3A85-06BE-43BC-9B84-2CA6F325612F"
        let storeUUID = "5FCC6F13-2CE3-48B1-907D-686244C0229A"
        let mailboxLeaf = "INBOX"
        let rowId = 262653

        // thousands=2, tenthousands=6, hundredthousands=2 → "2/6/2"
        let messagesDir = mailV10
            .appendingPathComponent(accountUUID)
            .appendingPathComponent("\(mailboxLeaf).mbox")
            .appendingPathComponent(storeUUID)
            .appendingPathComponent("Data/2/6/2/Messages", isDirectory: true)
        try fm.createDirectory(at: messagesDir, withIntermediateDirectories: true)

        let emlxFile = messagesDir.appendingPathComponent("\(rowId).emlx")
        let fakeEmlx = "10\nheader: x\n\nbody\n"
        try fakeEmlx.data(using: .utf8)!.write(to: emlxFile)

        // Point the resolver at our fake V10 root.
        let originalBase = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = mailV10.path
        defer { EnvelopeIndexReader.mailStoragePathOverride = originalBase }

        let mailboxURL = "ews://\(accountUUID)/\(mailboxLeaf)"
        let resolved = EmlxParser.resolveEmlxPath(rowId: rowId, mailboxURL: mailboxURL)

        XCTAssertEqual(
            resolved, emlxFile.path,
            "resolveEmlxPath must use thousands/tenthousands/hundredthousands hash"
        )
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
