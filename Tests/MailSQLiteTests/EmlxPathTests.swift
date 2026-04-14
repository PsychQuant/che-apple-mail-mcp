import XCTest
import SQLite3
@testable import MailSQLite

final class EmlxPathTests: XCTestCase {

    // MARK: - Hash Directory Calculation

    // Apple Mail V10 hashes message IDs by the decimal digits of
    // `rowId / 1000`, right-to-left. The directory depth is dynamic:
    // messages below ROWID 1000 go directly under `Data/Messages/`
    // (depth 0); 4-digit rowIds get one hash level; 5-digit rowIds
    // get two; and so on. Verified against 256,428 real .emlx files
    // on macOS Sequoia / Tahoe — see #9.
    //
    // Expected output of hashDirectoryPath:
    //   rowId 218    → ""      (depth 0, file at Data/Messages/218.emlx)
    //   rowId 9865   → "9"     (depth 1, 9865/1000 = 9)
    //   rowId 19926  → "9/1"   (depth 2, 19926/1000 = 19 → 9, 1)
    //   rowId 262653 → "2/6/2" (depth 3, 262653/1000 = 262 → 2, 6, 2)
    //   rowId 1234567 → "4/3/2/1" (depth 4)

    func testHashDirectoryForDepth3RealRowId() {
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 262653), "2/6/2")
    }

    func testHashDirectoryForDepth3AnotherRealRowId() {
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 267943), "7/6/2")
    }

    func testHashDirectoryForDepth2RealRowId() {
        // 19926 / 1000 = 19 → d4=9, d5=1
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 19926), "9/1")
    }

    func testHashDirectoryForDepth2MaxRealRowId() {
        // 99173 / 1000 = 99 → d4=9, d5=9
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 99173), "9/9")
    }

    func testHashDirectoryForDepth1RealRowId() {
        // 9865 / 1000 = 9 → single-level "9"
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 9865), "9")
    }

    func testHashDirectoryForDepth1MinRealRowId() {
        // 1805 / 1000 = 1 → single-level "1"
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 1805), "1")
    }

    func testHashDirectoryForDepth0SmallRowId() {
        // ROWID 218 sits directly under Data/Messages/ — no hash dir
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 218), "")
    }

    func testHashDirectoryForDepth0SingleDigit() {
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 5), "")
    }

    func testHashDirectoryForZero() {
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 0), "")
    }

    func testHashDirectoryForExactlyOneThousand() {
        // 1000 / 1000 = 1 → single-digit hash "1"
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 1000), "1")
    }

    func testHashDirectoryForJustBelowOneThousand() {
        // 999 / 1000 = 0 → no hash dir
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 999), "")
    }

    func testHashDirectoryForDepth4SevenDigitRowId() {
        // 1234567 / 1000 = 1234 → "4/3/2/1"
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 1234567), "4/3/2/1")
    }

    func testHashDirectoryForDepth5EightDigitRowId() {
        // 12345678 / 1000 = 12345 → "5/4/3/2/1"
        XCTAssertEqual(EmlxParser.hashDirectoryPath(rowId: 12345678), "5/4/3/2/1")
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

    /// Regression test for #9: resolveEmlxPath must find files at every
    /// depth level Apple Mail V10 uses — 0 (no hash dir), 1, 2, 3, and
    /// deeper. Exercises all four observed layouts with a fake
    /// ~/Library/Mail/V10 tree in /tmp.
    func testResolveEmlxPathFindsFilesAtAllDepths() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "emlx-fixture-alldepths-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: tmp) }

        let mailV10 = tmp.appendingPathComponent("Library/Mail/V10", isDirectory: true)
        let accountUUID = "ABCE3A85-06BE-43BC-9B84-2CA6F325612F"
        let storeUUID = "5FCC6F13-2CE3-48B1-907D-686244C0229A"
        let mailboxLeaf = "INBOX"

        // (rowId, expected hash dir)
        let cases: [(Int, String)] = [
            (218,    ""),        // depth 0
            (1805,   "1"),       // depth 1 min
            (9865,   "9"),       // depth 1 max
            (19926,  "9/1"),     // depth 2
            (99173,  "9/9"),     // depth 2 max
            (262653, "2/6/2"),   // depth 3 (real BMC email from #9 repro)
            (999999, "9/9/9"),   // depth 3 max
            (1234567, "4/3/2/1") // depth 4
        ]

        let mboxStoreDir = mailV10
            .appendingPathComponent(accountUUID)
            .appendingPathComponent("\(mailboxLeaf).mbox")
            .appendingPathComponent(storeUUID)

        for (rowId, expectedHash) in cases {
            let messagesDir: URL
            if expectedHash.isEmpty {
                messagesDir = mboxStoreDir.appendingPathComponent("Data/Messages", isDirectory: true)
            } else {
                messagesDir = mboxStoreDir
                    .appendingPathComponent("Data/\(expectedHash)/Messages", isDirectory: true)
            }
            try fm.createDirectory(at: messagesDir, withIntermediateDirectories: true)
            let emlx = messagesDir.appendingPathComponent("\(rowId).emlx")
            try "10\nheader: x\n\nbody\n".data(using: .utf8)!.write(to: emlx)
        }

        let originalBase = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = mailV10.path
        defer { EnvelopeIndexReader.mailStoragePathOverride = originalBase }

        let mailboxURL = "ews://\(accountUUID)/\(mailboxLeaf)"
        for (rowId, expectedHash) in cases {
            let resolved = EmlxParser.resolveEmlxPath(rowId: rowId, mailboxURL: mailboxURL)
            XCTAssertNotNil(
                resolved,
                "resolveEmlxPath(rowId: \(rowId)) returned nil; expected depth \(expectedHash.isEmpty ? "0 (no hash dir)" : expectedHash)"
            )
            if let resolved = resolved {
                XCTAssertTrue(
                    resolved.hasSuffix("/\(rowId).emlx"),
                    "Resolved path \(resolved) does not end with /\(rowId).emlx"
                )
                let expectedSegment: String
                if expectedHash.isEmpty {
                    expectedSegment = "/Data/Messages/"
                } else {
                    expectedSegment = "/Data/\(expectedHash)/Messages/"
                }
                XCTAssertTrue(
                    resolved.contains(expectedSegment),
                    "Resolved path \(resolved) missing expected segment \(expectedSegment)"
                )
            }
        }
    }

    /// Original single-depth regression test (kept as the minimal repro for #9).
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
