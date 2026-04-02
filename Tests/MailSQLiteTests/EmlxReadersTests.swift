import XCTest
@testable import MailSQLite

final class EmlxReadersTests: XCTestCase {

    // MARK: - Helpers

    private func makeReader() throws -> EnvelopeIndexReader {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available at \(path)")
        }
        return try EnvelopeIndexReader(databasePath: path)
    }

    /// Find a message whose .emlx file actually exists on disk.
    private func findReadableMessage(reader: EnvelopeIndexReader) throws -> (rowId: Int, mailboxURL: String) {
        let searchParams = SearchParameters(query: "a", limit: 20)
        let results = try reader.search(searchParams)

        for result in results {
            if let mbURL = try reader.mailboxURL(forMessageId: result.id),
               EmlxParser.resolveEmlxPath(rowId: result.id, mailboxURL: mbURL) != nil {
                return (result.id, mbURL)
            }
        }
        throw XCTSkip("No readable .emlx file found on disk")
    }

    // MARK: - readHeaders

    func testReadHeadersReturnsHeaderText() throws {
        let reader = try makeReader()
        let msg = try findReadableMessage(reader: reader)

        let headers = try EmlxParser.readHeaders(rowId: msg.rowId, mailboxURL: msg.mailboxURL)
        XCTAssertTrue(
            headers.contains("From:") || headers.contains("Subject:"),
            "Headers should contain 'From:' or 'Subject:', got prefix: \(String(headers.prefix(200)))"
        )
    }

    // MARK: - readSource

    func testReadSourceReturnsFullMessage() throws {
        let reader = try makeReader()
        let msg = try findReadableMessage(reader: reader)

        let source = try EmlxParser.readSource(rowId: msg.rowId, mailboxURL: msg.mailboxURL)
        XCTAssertGreaterThan(
            source.utf8.count, 100,
            "Source should be longer than 100 bytes, got \(source.utf8.count)"
        )
    }

    // MARK: - Error Handling

    func testReadHeadersThrowsForInvalidId() throws {
        XCTAssertThrowsError(
            try EmlxParser.readHeaders(rowId: 999_999_999, mailboxURL: "imap://fake/INBOX")
        ) { error in
            XCTAssertTrue(
                error is MailSQLiteError,
                "Expected MailSQLiteError, got \(type(of: error)): \(error)"
            )
        }
    }
}
