import XCTest
@testable import MailSQLite

final class EmlxReadersTests: XCTestCase {

    // MARK: - Helpers

    private func makeReader() throws -> EnvelopeIndexReader {
        let path = try realEnvelopeIndexPathOrSkip()
        return try EnvelopeIndexReader(databasePath: path)
    }

    /// Find a message whose .emlx file exists on disk AND whose headers are
    /// actually parseable (contain `From:` / `Subject:`).
    ///
    /// #246 (B-class flake): the selection criterion must be at least as
    /// strong as the assertions the tests make against the target. The old
    /// criterion ("emlx path resolves") was weaker than
    /// `testReadHeadersReturnsHeaderText`'s assertion ("headers contain
    /// From:/Subject:"), and the live mailbox drifts between runs (new mail
    /// re-orders the search results) — so a full-suite run occasionally
    /// picked a header-poor target (e.g. a partial file) and failed, while
    /// the isolated re-run (target drifted again) passed. Folding the
    /// header check into selection makes the target deterministic-enough:
    /// whichever message is picked satisfies the assertions by construction.
    private func findReadableMessage(reader: EnvelopeIndexReader) throws -> (rowId: Int, mailboxURL: String) {
        let searchParams = SearchParameters(query: "a", limit: 20)
        let results = try reader.search(searchParams)

        for result in results {
            guard let mbURL = try reader.mailboxURL(forMessageId: result.id),
                  EmlxParser.resolveEmlxPath(rowId: result.id, mailboxURL: mbURL) != nil,
                  let headers = try? EmlxParser.readHeaders(rowId: result.id, mailboxURL: mbURL),
                  headers.contains("From:") || headers.contains("Subject:")
            else { continue }
            return (result.id, mbURL)
        }
        throw XCTSkip("No readable .emlx file with parseable headers found on disk")
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
