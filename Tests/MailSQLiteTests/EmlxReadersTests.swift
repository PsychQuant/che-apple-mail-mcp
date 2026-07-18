import XCTest
@testable import MailSQLite

final class EmlxReadersTests: XCTestCase {

    // MARK: - Helpers

    private func makeReader() throws -> EnvelopeIndexReader {
        let path = try realEnvelopeIndexPathOrSkip()
        return try EnvelopeIndexReader(databasePath: path)
    }

    /// Find a live message satisfying the calling test's OWN assertion.
    ///
    /// #246 (B-class flake): the selection criterion must be at least as
    /// strong as the assertion the test makes against the target — the old
    /// criterion ("emlx path resolves") was weaker, and the live mailbox
    /// drifts between runs (new mail re-orders search results), so a
    /// full-suite run occasionally picked a target that failed the
    /// assertion while the isolated re-run (target drifted again) passed.
    /// Each test passes a `satisfying` predicate mirroring its assertion,
    /// so whichever candidate is picked passes by construction (modulo the
    /// inherent select-then-reread TOCTOU window of a live corpus).
    ///
    /// Error discipline (#246 verify R1, Codex): a candidate whose read
    /// throws is skipped, but if EVERY resolvable candidate threw, that is
    /// a parser-regression signal — rethrow the last error so the suite
    /// FAILS instead of silently degrading to XCTSkip. XCTSkip remains for
    /// genuine corpus limitations only (nothing resolvable, or readable
    /// candidates simply don't satisfy the criterion).
    private func findReadableMessage(
        reader: EnvelopeIndexReader,
        satisfying predicate: (Int, String) throws -> Bool
    ) throws -> (rowId: Int, mailboxURL: String) {
        let searchParams = SearchParameters(query: "a", limit: 20)
        let results = try reader.search(searchParams)

        var sawResolvableCandidate = false
        var evaluatedWithoutError = false
        var lastReadError: Error?
        for result in results {
            guard let mbURL = try reader.mailboxURL(forMessageId: result.id),
                  EmlxParser.resolveEmlxPath(rowId: result.id, mailboxURL: mbURL) != nil
            else { continue }
            sawResolvableCandidate = true
            do {
                if try predicate(result.id, mbURL) {
                    return (result.id, mbURL)
                }
                evaluatedWithoutError = true
            } catch {
                lastReadError = error
            }
        }
        if sawResolvableCandidate, !evaluatedWithoutError, let err = lastReadError {
            // Every resolvable candidate threw — surface the regression.
            throw err
        }
        throw XCTSkip("No live .emlx candidate satisfies the test's criterion")
    }

    // MARK: - readHeaders

    func testReadHeadersReturnsHeaderText() throws {
        let reader = try makeReader()
        // Selection predicate mirrors this test's assertion (#246).
        let msg = try findReadableMessage(reader: reader) { rowId, mbURL in
            let h = try EmlxParser.readHeaders(rowId: rowId, mailboxURL: mbURL)
            return h.contains("From:") || h.contains("Subject:")
        }

        let headers = try EmlxParser.readHeaders(rowId: msg.rowId, mailboxURL: msg.mailboxURL)
        XCTAssertTrue(
            headers.contains("From:") || headers.contains("Subject:"),
            "Headers should contain 'From:' or 'Subject:', got prefix: \(String(headers.prefix(200)))"
        )
    }

    // MARK: - readSource

    func testReadSourceReturnsFullMessage() throws {
        let reader = try makeReader()
        // Selection predicate mirrors this test's assertion (#246 verify R1,
        // Codex: header-readable does NOT imply source > 100 bytes — each
        // test needs its own criterion).
        let msg = try findReadableMessage(reader: reader) { rowId, mbURL in
            let s = try EmlxParser.readSource(rowId: rowId, mailboxURL: mbURL)
            return s.utf8.count > 100
        }

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
