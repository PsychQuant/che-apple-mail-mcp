import XCTest
import SQLite3
@testable import MailSQLite

final class DraftStatusTests: XCTestCase {
    private func fixture(typeColumn: Bool = true) throws -> EnvelopeIndexReader {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft374-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE recipients (message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER,
          date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
          size INTEGER DEFAULT 10, conversation_id INTEGER DEFAULT 1, flags INTEGER DEFAULT 0, global_message_id INTEGER\(typeColumn ? ", type" : ""));
        INSERT INTO addresses VALUES (1, 'sender@example.test', 'Fixture');
        INSERT INTO mailboxes VALUES (1, 'imap://UUID-A/%5BGmail%5D/%E8%8D%89%E7%A8%BF');
        INSERT INTO mailboxes VALUES (2, 'imap://UUID-A/%5BGmail%5D/All%20Mail');
        INSERT INTO mailboxes VALUES (3, 'imap://UUID-A/Projects/Drafts');
        """
        for subject in 1...8 { sql += "INSERT INTO subjects VALUES (\(subject), 'match \(subject)');\n" }
        let rows: [(Int, Int, Int, String)] = [
            (1, 1, 1, "5"), (2, 1, 2, "5"), (3, 2, 3, "0"),
            (4, 3, 2, "6"), (5, 4, 2, "NULL"), (6, 5, 2, "'5'"),
            (7, 6, 2, "0"), (8, 6, 1, "5"), (9, 7, 1, "5"), (10, 7, 2, "0")
        ]
        for (id, subject, mailbox, type) in rows {
            sql += "INSERT INTO messages (ROWID,subject,sender,mailbox,date_received,global_message_id\(typeColumn ? ",type" : "")) VALUES (\(id),\(subject),1,\(mailbox),\(1000 + subject),\(id)\(typeColumn ? "," + type : ""));\n"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "DraftStatusFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return try EnvelopeIndexReader(databasePath: path, accountMapping: ["UUID-A": "Fixture"])
    }

    func testFullAndSummaryCarryPerMessageFactsWithoutMailboxInference() throws {
        let reader = try fixture()
        let params = SearchParameters(query: "match", field: .subject, limit: 30)
        for rows in [try reader.searchPage(params).results, try reader.searchSummaryPage(params).results] {
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            XCTAssertEqual(byID[1]?.isDraft, true)
            XCTAssertEqual(byID[2]?.isDraft, true, "All Mail copy remains a draft")
            // A folder called Drafts is not evidence of a draft, but it does
            // withhold "known non-draft": type 0 is not enough there (#374 verify).
            XCTAssertNil(byID[3]?.isDraft, "a Drafts-named folder withholds false")
            for id in [4, 5, 6] { XCTAssertNil(byID[id]?.isDraft) }
        }
    }

    func testLogicalDedupFlagFollowsTheSelectedMinimumRow() throws {
        let reader = try fixture()
        let page = try reader.searchSummaryPage(SearchParameters(query: "match", field: .subject, limit: 30), dedup: true)
        let byID = Dictionary(uniqueKeysWithValues: page.results.map { ($0.id, $0) })
        XCTAssertEqual(byID[1]?.isDraft, true)
        XCTAssertNil(byID[2])
        XCTAssertEqual(byID[7]?.isDraft, false)
        XCTAssertNil(byID[8])
        XCTAssertEqual(byID[9]?.isDraft, true)
        XCTAssertNil(byID[10])
    }

    func testListMetadataAndDirectLookupAgree() throws {
        let reader = try fixture()
        let allMail = try reader.listEmails(mailbox: "[Gmail]/All Mail", accountName: "Fixture", limit: 30)
        XCTAssertEqual(allMail.first { $0["id"] as? String == "2" }?["is_draft"] as? Bool, true)
        let ordinary = try reader.listEmails(mailbox: "Projects/Drafts", accountName: "Fixture")
        XCTAssertTrue(ordinary.first?["is_draft"] is NSNull, "type 0 in a Drafts-named folder is unknown")
        for id in [1, 2, 3, 4, 5, 6] {
            let status = try reader.messageIsDraft(messageId: id)
            let metadata = try reader.getEmailMetadata(messageId: id)
            if let status { XCTAssertEqual(metadata["is_draft"] as? Bool, status) }
            else { XCTAssertTrue(metadata["is_draft"] is NSNull) }
        }
        XCTAssertThrowsError(try reader.messageIsDraft(messageId: 999))
    }

    func testMissingColumnKeepsQueriesWorkingWithUnknownEvidence() throws {
        let reader = try fixture(typeColumn: false)
        let params = SearchParameters(query: "match", field: .subject, limit: 2)
        XCTAssertTrue(try reader.searchPage(params).truncated)
        XCTAssertTrue(try reader.searchPage(params).results.allSatisfy { $0.isDraft == nil })
        XCTAssertTrue(try reader.searchSummaryPage(params, dedup: true).results.allSatisfy { $0.isDraft == nil })
        XCTAssertTrue(try reader.getEmailMetadata(messageId: 1)["is_draft"] is NSNull)
        XCTAssertNil(try reader.messageIsDraft(messageId: 1))
        XCTAssertTrue(try reader.listEmails(mailbox: "[Gmail]/All Mail", accountName: "Fixture").allSatisfy { $0["is_draft"] is NSNull })
    }

    /// Drafts synced from a server or another device are stored with type 0.
    /// Mail's draft flag (0x40) and the other copies of the same message are
    /// evidence; a Drafts-named folder only keeps type 0 from meaning "known
    /// non-draft" (#374 verify).
    private func evidenceFixture() throws -> EnvelopeIndexReader { try evidenceIndex().reader }

    private func evidenceIndex() throws -> (reader: EnvelopeIndexReader, path: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft374e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE recipients (message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER,
          date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
          size INTEGER DEFAULT 10, conversation_id INTEGER DEFAULT 1, type INTEGER, flags INTEGER, global_message_id INTEGER);
        INSERT INTO addresses VALUES (1, 'sender@example.test', 'Fixture');
        INSERT INTO mailboxes VALUES (1, 'imap://UUID-A/%5BGmail%5D/%E8%8D%89%E7%A8%BF');
        INSERT INTO mailboxes VALUES (2, 'imap://UUID-A/%5BGmail%5D/All%20Mail');
        INSERT INTO mailboxes VALUES (3, 'ews://UUID-A/Sent%20Items');
        INSERT INTO mailboxes VALUES (4, 'ews://UUID-A/Entw%C3%BCrfe');
        """
        // (id, mailbox, type, flags, global id)
        let rows: [(Int, Int, Int, Int, Int)] = [
            (1, 2, 0, 64, 900),   // flag on the row itself
            (2, 2, 0, 0, 901), (3, 1, 0, 64, 901),   // a copy carries the flag
            (4, 2, 0, 0, 902), (5, 1, 0, 0, 902),    // no evidence, but a copy is in a Drafts folder
            (6, 3, 0, 0, 903),                       // sent mail, no copy anywhere else
            (7, 4, 0, 0, 904),                       // a localized drafts folder name
            (8, 2, 0, 0, 905), (9, 3, 5, 0, 905),    // a copy has type 5
        ]
        for (id, mailbox, type, flags, global) in rows {
            sql += "INSERT INTO subjects VALUES (\(id), 'match \(id)');\n"
            sql += "INSERT INTO messages (ROWID,subject,sender,mailbox,date_received,type,flags,global_message_id) "
                + "VALUES (\(id),\(id),1,\(mailbox),\(1000 + id),\(type),\(flags),\(global));\n"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "DraftStatusFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return (try EnvelopeIndexReader(databasePath: path, accountMapping: ["UUID-A": "Fixture"]), path)
    }

    private func execute(_ sql: String, at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "DraftStatusFixture", code: 3) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "DraftStatusFixture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// One type-0 message plus an optional copy, in a schema with the given
    /// columns, opened as a reader.
    private func schemaIndex(columns: String, rows: [String]) throws -> EnvelopeIndexReader {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft374s-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index").path
        try execute("""
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE recipients (message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER,
          date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
          size INTEGER DEFAULT 10, conversation_id INTEGER DEFAULT 1, \(columns));
        INSERT INTO addresses VALUES (1, 'sender@example.test', 'Fixture');
        INSERT INTO subjects VALUES (1, 'match');
        INSERT INTO mailboxes VALUES (1, 'imap://UUID-A/INBOX');
        INSERT INTO mailboxes VALUES (2, NULL);
        \(rows.joined(separator: "\n"))
        """, at: path)
        return try EnvelopeIndexReader(databasePath: path, accountMapping: ["UUID-A": "Fixture"])
    }

    /// False needs every piece of evidence present and negative; a missing
    /// column, a NULL value or an unknown folder leaves the status unknown
    /// (#374 verify).
    func testFalseNeedsEveryPieceOfEvidence() throws {
        let full = "type INTEGER, flags INTEGER, global_message_id INTEGER"
        let insert = "INSERT INTO messages (ROWID,subject,sender,mailbox,date_received,type,flags,global_message_id) VALUES "
        let clean = try schemaIndex(columns: full, rows: [insert + "(1,1,1,1,1000,0,0,7);"])
        XCTAssertEqual(try clean.messageIsDraft(messageId: 1), false, "control: every piece present and negative")
        let cases: [(String, String, [String])] = [
            ("no flags column", "type INTEGER, global_message_id INTEGER",
             ["INSERT INTO messages (ROWID,subject,sender,mailbox,date_received,type,global_message_id) VALUES (1,1,1,1,1000,0,7);"]),
            ("no copy column", "type INTEGER, flags INTEGER",
             ["INSERT INTO messages (ROWID,subject,sender,mailbox,date_received,type,flags) VALUES (1,1,1,1,1000,0,0);"]),
            ("NULL flags", full, [insert + "(1,1,1,1,1000,0,NULL,7);"]),
            ("NULL global id", full, [insert + "(1,1,1,1,1000,0,0,NULL);"]),
            ("a copy with NULL flags", full, [insert + "(1,1,1,1,1000,0,0,7);", insert + "(2,1,1,1,1000,0,NULL,7);"]),
            ("a copy with NULL type", full, [insert + "(1,1,1,1,1000,0,0,7);", insert + "(2,1,1,1,1000,NULL,0,7);"]),
            ("a folder whose name is unknown", full, [insert + "(1,1,1,2,1000,0,0,7);"]),
            ("a mailbox row that does not exist", full, [insert + "(1,1,1,9,1000,0,0,7);"]),
            ("a copy in a folder whose name is unknown", full, [insert + "(1,1,1,1,1000,0,0,7);", insert + "(2,1,1,2,1000,0,0,7);"]),
        ]
        for (name, columns, rows) in cases {
            let reader = try schemaIndex(columns: columns, rows: rows)
            XCTAssertNil(try reader.messageIsDraft(messageId: 1), name)
        }
        let typeOnly = try schemaIndex(columns: "type INTEGER",
                                       rows: ["INSERT INTO messages (ROWID,subject,sender,mailbox,date_received,type) VALUES (1,1,1,1,1000,5);"])
        XCTAssertEqual(try typeOnly.messageIsDraft(messageId: 1), true, "type 5 is evidence without the other columns")
    }

    /// Folder names are read by every query, not once when the reader opens:
    /// a Drafts folder created, or a folder renamed to Drafts, while the server
    /// runs withholds false at once (#374 verify).
    func testAFolderCreatedOrRenamedAfterOpenWithholdsFalse() throws {
        let (reader, path) = try evidenceIndex()
        XCTAssertEqual(try reader.messageIsDraft(messageId: 6), false)
        try execute("UPDATE mailboxes SET url = 'ews://UUID-A/Drafts' WHERE ROWID = 3;", at: path)
        XCTAssertNil(try reader.messageIsDraft(messageId: 6), "renamed to Drafts")
        try execute("""
        UPDATE mailboxes SET url = 'ews://UUID-A/Sent%20Items' WHERE ROWID = 3;
        INSERT INTO mailboxes VALUES (9, 'imap://UUID-B/Drafts');
        INSERT INTO messages (ROWID,subject,sender,mailbox,date_received,type,flags,global_message_id)
          VALUES (20,6,1,9,1006,0,0,903);
        """, at: path)
        XCTAssertNil(try reader.messageIsDraft(messageId: 6), "a copy in a Drafts folder created after open")
        let params = SearchParameters(query: "match", field: .subject, limit: 30)
        let row = try XCTUnwrap(try reader.searchPage(params).results.first { $0.id == 6 })
        XCTAssertNil(row.isDraft, "search sees the new folder too")
    }

    /// A schema that cannot be inspected leaves draft status unknown instead of
    /// taking the reader offline (#374 verify).
    func testAnUninspectableSchemaGivesUnknownStatus() {
        XCTAssertEqual(EnvelopeIndexReader.resolveDraftStatusSQL(nil), "NULL")
    }

    func testDraftsFolderNamesFoldCaseAndPercentEncoding() {
        for url in ["imap://A/%5BGmail%5D/%E8%8D%89%E7%A8%BF", "imap://A/drafts", "ews://A/Entw%C3%BCrfe",
                    "imap://A/%5BGmail%5D/%EC%9E%84%EC%8B%9C%EB%B3%B4%EA%B4%80%ED%95%A8", "imap://A/Wersje%20robocze"] {
            XCTAssertTrue(EnvelopeIndexReader.isDraftsFolderURL(url), url)
        }
        for url in ["imap://A/INBOX", "imap://A/Drafts/Archive", "imap://A/%5BGmail%5D/All%20Mail"] {
            XCTAssertFalse(EnvelopeIndexReader.isDraftsFolderURL(url), url)
        }
    }

    func testTypeZeroIsANonDraftOnlyWithoutAnyDraftEvidence() throws {
        let reader = try evidenceFixture()
        let expected: [Int: Bool?] = [1: true, 2: true, 3: true, 4: nil, 5: nil, 6: false, 7: nil, 8: true, 9: true]
        let params = SearchParameters(query: "match", field: .subject, limit: 30)
        for rows in [try reader.searchPage(params).results, try reader.searchSummaryPage(params).results] {
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.isDraft) })
            for (id, value) in expected {
                XCTAssertTrue(byID.keys.contains(id), "row \(id) is returned")
                XCTAssertEqual(byID[id] ?? nil, value, "row \(id)")
            }
        }
        for (id, value) in expected {
            XCTAssertEqual(try reader.messageIsDraft(messageId: id), value, "row \(id)")
        }
    }
}

