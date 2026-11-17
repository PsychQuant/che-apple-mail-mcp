import SQLite3
import XCTest
@testable import MailSQLite

/// #682: `MessageIDLookup` turns search rows into value / empty string / unreadable, resolving each
/// mailbox's store folder once, and `SearchResult` carries the mailbox URL it needs.
final class SearchMessageIDTests: XCTestCase {

    /// A fixture index: rows `1...copies` are mailbox copies of one logical email (same subject,
    /// sender, date) in mailboxes `INBOX`, `Archive`, `Other`; row 10 is a separate email in INBOX.
    private func makeIndex(in root: URL) throws -> EnvelopeIndexReader {
        let path = root.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "SearchMessageIDTests", code: 1) }
        defer { sqlite3_close(db) }
        var sql = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, unread_count INTEGER DEFAULT 0);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER, date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        INSERT INTO addresses VALUES (1, 'sender@example.invalid', 'Sender');
        INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://UUID-A/INBOX'), (2, 'imap://UUID-A/Archive'), (3, 'imap://UUID-A/Other');
        INSERT INTO subjects VALUES (1, 'match one'), (2, 'match two');
        """
        for (row, mailbox) in [(1, 1), (2, 2), (3, 3)] {
            sql += "INSERT INTO messages (ROWID, subject, sender, mailbox, date_received) VALUES (\(row), 1, 1, \(mailbox), 2000);\n"
        }
        sql += "INSERT INTO messages (ROWID, subject, sender, mailbox, date_received) VALUES (10, 2, 1, 1, 1000);\n"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "SearchMessageIDTests", code: 2) }
        return try EnvelopeIndexReader(databasePath: path, accountMapping: ["UUID-A": "Fixture"])
    }

    private func message(_ id: String?) -> Data {
        Data(("Subject: s\r\n" + (id.map { "Message-ID: \($0)\r\n" } ?? "") + "\r\nbody").utf8)
    }

    func testSearchRowsCarryTheRawMailboxURL() throws {
        let store = try MessageIDStore(testCase: self)
        let reader = try makeIndex(in: store.root)
        let params = SearchParameters(query: "match", field: .subject, limit: 10)
        let full = try reader.searchPage(params).results
        let summary = try reader.searchSummaryPage(params).results
        XCTAssertEqual(Set(full.compactMap { $0.mailboxURL }), ["imap://UUID-A/INBOX", "imap://UUID-A/Archive", "imap://UUID-A/Other"])
        XCTAssertEqual(full.map { $0.mailboxURL }, summary.map { $0.mailboxURL })
        XCTAssertNil(SearchResult(id: 1, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                                  mailboxPath: "", isRead: false, isFlagged: false, toRecipients: []).mailboxURL)
    }

    // spec-example: sqlite-query-engine / the three message_id states on four rows
    func testThreeStatesAndTheRowsAreNeverDropped() throws {
        let store = try MessageIDStore(testCase: self)
        let reader = try makeIndex(in: store.root)
        try store.write(rowId: 1, message: message("<one@example.invalid>"))
        try store.write(rowId: 2, message: message(nil), mailbox: "Archive")
        // row 3 has no file; row 10 has a file whose value is too long
        try store.write(rowId: 10, message: message("<" + String(repeating: "x", count: 5000) + "@example.invalid>"))
        let results = try reader.searchPage(SearchParameters(query: "match", field: .subject, sort: .asc, limit: 10)).results
        XCTAssertEqual(results.count, 4)
        let outcomes = store.withStoragePath { MessageIDLookup().outcomes(for: results) }
        XCTAssertEqual(outcomes.rows.count, results.count, "a row is never dropped")
        XCTAssertEqual(outcomes.rows[results.firstIndex { $0.id == 1 }!], .value("<one@example.invalid>"))
        XCTAssertEqual(outcomes.rows[results.firstIndex { $0.id == 2 }!], .value(""), "no header is the empty string, not unreadable")
        XCTAssertEqual(outcomes.rows[results.firstIndex { $0.id == 3 }!], .unreadable(.noEmlx))
        XCTAssertEqual(outcomes.rows[results.firstIndex { $0.id == 10 }!], .unreadable(.tooLong))
        XCTAssertEqual(outcomes.unreadableCounts, [.noEmlx: 1, .tooLong: 1])
        XCTAssertEqual(MessageIDLookup.maxLength, 4096)
    }

    // spec-example: sqlite-query-engine / the omitted-key cases and their reasons
    func testAValueOfExactlyTheLimitIsReturnedAndOneMoreIsNot() throws {
        let store = try MessageIDStore(testCase: self)
        let at = "<" + String(repeating: "y", count: MessageIDLookup.maxLength - 2) + ">"
        XCTAssertEqual(at.utf8.count, MessageIDLookup.maxLength)
        try store.write(rowId: 1, message: message(at))
        try store.write(rowId: 2, message: message(at + "z"))
        let rows = [1, 2].map { SearchResult(id: $0, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                                           mailboxPath: "INBOX", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL()) }
        let outcomes = store.withStoragePath { MessageIDLookup().outcomes(for: rows) }
        XCTAssertEqual(outcomes.rows, [.value(at), .unreadable(.tooLong)])
    }

    // The cap is in UTF-8 bytes: one base character and many combining marks is a few
    // Characters but many bytes.
    func testTheValueCapCountsUTF8BytesNotCharacters() throws {
        let store = try MessageIDStore(testCase: self)
        let marks = "<a" + String(repeating: "\u{0301}", count: 3000) + ">"
        XCTAssertLessThan(marks.count, MessageIDLookup.maxLength, "few Characters")
        XCTAssertGreaterThan(marks.utf8.count, MessageIDLookup.maxLength)
        let row = SearchResult(id: 1, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                               mailboxPath: "INBOX", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL())
        try store.write(rowId: 1, message: message(marks))
        let viaReader = store.withStoragePath { MessageIDLookup().outcomes(for: [row]).rows[0] }
        XCTAssertEqual(viaReader, .unreadable(.tooLong))
        let injected = store.withStoragePath { MessageIDLookup(readFile: { _ in marks }).outcomes(for: [row]).rows[0] }
        XCTAssertEqual(injected, .unreadable(.tooLong))
    }

    // spec-example: sqlite-query-engine / the omitted-key cases and their reasons
    func testAHeaderBlockOverTheCapIsUnreadableWithItsOwnReason() throws {
        let store = try MessageIDStore(testCase: self)
        try store.write(rowId: 1, message: Data("Message-ID: <x@example.invalid>\r\n".utf8) + Data(repeating: 0x41, count: 600_000))
        let row = SearchResult(id: 1, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                               mailboxPath: "INBOX", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL())
        XCTAssertEqual(store.withStoragePath { MessageIDLookup().outcomes(for: [row]).rows[0] }, .unreadable(.headerTooLarge))
    }

    // spec-example: sqlite-query-engine / the omitted-key cases and their reasons
    func testAMissingMailboxURLOrAnUnknownMailboxIsUnreadable() throws {
        let store = try MessageIDStore(testCase: self)
        let nilURL = SearchResult(id: 1, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                                  mailboxPath: "", isRead: false, isFlagged: false, toRecipients: [])
        let unknown = SearchResult(id: 1, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                                   mailboxPath: "", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: "imap://UUID-A/Nope")
        let outcomes = store.withStoragePath { MessageIDLookup().outcomes(for: [nilURL, unknown]) }
        XCTAssertEqual(outcomes.rows, [.unreadable(.noEmlx), .unreadable(.noEmlx)])
    }

    func testAFailingReadIsUnreadableAndTheReasonCarriesNoFileText() throws {
        let store = try MessageIDStore(testCase: self)
        try store.write(rowId: 1, message: message("<one@example.invalid>"))
        struct Boom: Error, CustomStringConvertible { var description: String { "SECRET-HEADER-TEXT" } }
        let lookup = MessageIDLookup(readFile: { _ in throw Boom() })
        let row = SearchResult(id: 1, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                               mailboxPath: "INBOX", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL())
        let outcomes = store.withStoragePath { lookup.outcomes(for: [row]) }
        XCTAssertEqual(outcomes.rows, [.unreadable(.readFailed)])
        XCTAssertFalse(MessageIDLookup.Unreadable.readFailed.rawValue.contains("SECRET"))
    }

    // The store folder of a mailbox is looked up once per call, not once per row.
    func testTheStoreFolderIsResolvedOncePerMailbox() throws {
        let store = try MessageIDStore(testCase: self)
        for row in [1, 2, 3, 4] { try store.write(rowId: row, message: message("<m\(row)@example.invalid>")) }
        try store.write(rowId: 5, message: message("<m5@example.invalid>"), mailbox: "Archive")
        let rows = [1, 2, 3, 4].map { SearchResult(id: $0, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                                                  mailboxPath: "INBOX", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL()) }
            + [SearchResult(id: 5, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                            mailboxPath: "Archive", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL("Archive"))]
        var finderCalls: [String] = []
        let lookup = MessageIDLookup(storeFinder: { dir in finderCalls.append(dir); return EmlxParser.findStoreUUID(in: dir) })
        let outcomes = store.withStoragePath { lookup.outcomes(for: rows) }
        XCTAssertEqual(outcomes.rows.count, 5)
        XCTAssertEqual(finderCalls.count, 2, "one directory listing per mailbox: \(finderCalls)")
        XCTAssertEqual(Set(finderCalls).count, 2)
        // A second call on the same lookup instance reuses the cache.
        _ = store.withStoragePath { lookup.outcomes(for: rows) }
        XCTAssertEqual(finderCalls.count, 2)
        // A fresh instance (a new search call) looks again.
        _ = store.withStoragePath { MessageIDLookup(storeFinder: { dir in finderCalls.append(dir); return EmlxParser.findStoreUUID(in: dir) }).outcomes(for: rows) }
        XCTAssertEqual(finderCalls.count, 4)
    }

    // A mailbox with no store folder is also looked up once, not once per row.
    func testAMailboxWithNoStoreFolderIsNotLookedUpAgain() throws {
        let store = try MessageIDStore(testCase: self)
        let rows = [1, 2, 3].map { SearchResult(id: $0, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                                               mailboxPath: "Nope", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL("Nope")) }
        var calls = 0
        let lookup = MessageIDLookup(storeFinder: { _ in calls += 1; return nil })
        let outcomes = store.withStoragePath { lookup.outcomes(for: rows) }
        XCTAssertEqual(outcomes.rows, [.unreadable(.noEmlx), .unreadable(.noEmlx), .unreadable(.noEmlx)])
        XCTAssertEqual(calls, 1)
    }

    // spec: with dedup logical and summary, the value is the kept MIN(ROWID) row's.
    func testDedupLogicalSummaryUsesTheKeptRow() throws {
        let store = try MessageIDStore(testCase: self)
        let reader = try makeIndex(in: store.root)
        try store.write(rowId: 1, message: message("<kept@example.invalid>"))
        try store.write(rowId: 2, message: message("<copy2@example.invalid>"), mailbox: "Archive")
        try store.write(rowId: 3, message: message("<copy3@example.invalid>"), mailbox: "Other")
        let page = try reader.searchSummaryPage(SearchParameters(query: "match one", field: .subject, limit: 10), dedup: true)
        XCTAssertEqual(page.results.map { $0.id }, [1])
        let outcomes = store.withStoragePath { MessageIDLookup().outcomes(for: page.results) }
        XCTAssertEqual(outcomes.rows, [.value("<kept@example.invalid>")])
    }

    // The lookup equals readEmail's value for the same row through the store.
    func testLookupEqualsReadEmailForEverySample() throws {
        let store = try MessageIDStore(testCase: self)
        try store.withStoragePath {
            for (index, sample) in MessageIDSamples.all.enumerated() {
                let rowId = index + 1
                try store.write(rowId: rowId, message: sample.message)
                let row = SearchResult(id: rowId, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                                       mailboxPath: "INBOX", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL())
                let viaEmail = try EmlxParser.readEmail(rowId: rowId, mailboxURL: MessageIDStore.mailboxURL()).messageId
                let outcome = MessageIDLookup().outcomes(for: [row]).rows[0]
                if viaEmail.utf8.count > MessageIDLookup.maxLength {
                    XCTAssertEqual(outcome, .unreadable(.tooLong), sample.name)
                } else {
                    XCTAssertEqual(outcome, .value(viaEmail), sample.name)
                }
            }
        }
    }

    // A partial .emlx (body not downloaded) still has its header block.
    func testAPartialEmlxIsReadLikeGetEmail() throws {
        let store = try MessageIDStore(testCase: self)
        let dir = store.messagesDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let msg = message("<partial@example.invalid>")
        try (Data("\(msg.count)\n".utf8) + msg).write(to: dir.appendingPathComponent("7.partial.emlx"))
        let row = SearchResult(id: 7, subject: "", senderAddress: "", senderName: "", dateReceived: Date(), accountName: "",
                               mailboxPath: "INBOX", isRead: false, isFlagged: false, toRecipients: [], mailboxURL: MessageIDStore.mailboxURL())
        let outcome = store.withStoragePath { MessageIDLookup().outcomes(for: [row]).rows[0] }
        XCTAssertEqual(outcome, .value("<partial@example.invalid>"))
        XCTAssertEqual(try store.withStoragePath { try EmlxParser.readEmail(rowId: 7, mailboxURL: MessageIDStore.mailboxURL()).messageId }, "<partial@example.invalid>")
    }
}
