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
          size INTEGER DEFAULT 10, conversation_id INTEGER DEFAULT 1\(typeColumn ? ", type" : ""));
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
            sql += "INSERT INTO messages (ROWID,subject,sender,mailbox,date_received\(typeColumn ? ",type" : "")) VALUES (\(id),\(subject),1,\(mailbox),\(1000 + subject)\(typeColumn ? "," + type : ""));\n"
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
            XCTAssertEqual(byID[3]?.isDraft, false, "folder called Drafts is not evidence")
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
        XCTAssertEqual(ordinary.first?["is_draft"] as? Bool, false)
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
}
