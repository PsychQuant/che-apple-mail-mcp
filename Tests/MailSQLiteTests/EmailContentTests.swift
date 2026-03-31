import XCTest
@testable import MailSQLite

final class EmailContentTests: XCTestCase {

    func testReadEmailFromEmlx() throws {
        let dbPath = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Envelope Index not available")
        }

        let reader = try EnvelopeIndexReader(databasePath: dbPath)
        let results = try reader.search(SearchParameters(query: "a", limit: 10))

        // Try to read at least one email via emlx
        var readOne = false
        for result in results {
            guard let mailboxUrl = try reader.mailboxURL(forMessageId: result.id) else { continue }
            guard let path = EmlxParser.resolveEmlxPath(rowId: result.id, mailboxURL: mailboxUrl) else { continue }

            do {
                let content = try EmlxParser.readEmail(
                    rowId: result.id,
                    mailboxURL: mailboxUrl,
                    format: "html"
                )
                XCTAssertFalse(content.subject.isEmpty, "Subject should not be empty")
                XCTAssertFalse(content.sender.isEmpty, "Sender should not be empty")
                // At least one of text or html body should be present
                XCTAssertTrue(content.textBody != nil || content.htmlBody != nil,
                    "Should have text or html body for message \(result.id)")
                readOne = true
                break
            } catch {
                continue // Some messages may not have .emlx files
            }
        }

        if !readOne {
            throw XCTSkip("Could not find a readable .emlx file")
        }
    }

    func testReadEmailSource() throws {
        let dbPath = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Envelope Index not available")
        }

        let reader = try EnvelopeIndexReader(databasePath: dbPath)
        let results = try reader.search(SearchParameters(query: "a", limit: 10))

        for result in results {
            guard let mailboxUrl = try reader.mailboxURL(forMessageId: result.id) else { continue }
            guard EmlxParser.resolveEmlxPath(rowId: result.id, mailboxURL: mailboxUrl) != nil else { continue }

            do {
                let content = try EmlxParser.readEmail(
                    rowId: result.id,
                    mailboxURL: mailboxUrl,
                    format: "source"
                )
                XCTAssertNotNil(content.rawSource, "Source format should include raw data")
                XCTAssertGreaterThan(content.rawSource!.count, 0)
                return
            } catch {
                continue
            }
        }

        throw XCTSkip("Could not find a readable .emlx file for source test")
    }

    func testReadEmailNotFound() {
        XCTAssertThrowsError(
            try EmlxParser.readEmail(rowId: 999999999, mailboxURL: "imap://fake/INBOX")
        ) { error in
            XCTAssertTrue(error is MailSQLiteError)
        }
    }
}
