import XCTest
@testable import MailSQLite

/// #177: the `summary` projection returns id/subject/sender/date/mailbox with no
/// recipient subquery, ordered identically to `ids`, and dedups identically when
/// asked. FDA-gated (needs the real Envelope Index) — skipped in CI.
final class SummaryProjectionTests: XCTestCase {

    private func makeReader() throws -> EnvelopeIndexReader {
        let dbPath = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Envelope Index not available (no Full Disk Access)")
        }
        do { return try EnvelopeIndexReader(databasePath: dbPath) }
        catch { throw XCTSkip("Could not open Envelope Index: \(error)") }
    }

    /// `summary` selects the same rows in the same order as `ids` (both ordered by
    /// `date_received, ROWID`) and performs no recipient fetch.
    func testSummaryParityWithIds_andNoRecipients() throws {
        let reader = try makeReader()
        let params = SearchParameters(query: "a", field: .any, sort: .desc, limit: 20)
        let summary = try reader.searchSummaryPage(params)
        let ids = try reader.searchIds(params)

        XCTAssertEqual(summary.results.map { $0.id }, ids.ids,
                       "summary must select the same rowIds, in the same order, as the ids projection")
        XCTAssertEqual(summary.truncated, ids.truncated,
                       "summary truncation must match the ids projection's")
        for r in summary.results {
            XCTAssertTrue(r.toRecipients.isEmpty,
                          "summary must NOT perform the per-row recipient subquery")
        }
    }

    /// `summary` + dedup collapses the same logical-email groups as `ids` + dedup.
    func testSummaryDedupParityWithIdsDedup() throws {
        let reader = try makeReader()
        let params = SearchParameters(query: "a", field: .any, sort: .desc, limit: 20)
        let summary = try reader.searchSummaryPage(params, dedup: true)
        let ids = try reader.searchIds(params, dedup: true)

        XCTAssertEqual(summary.results.map { $0.id }, ids.ids,
                       "summary dedup must collapse the same groups (MIN(ROWID)) as ids dedup")
    }
}
