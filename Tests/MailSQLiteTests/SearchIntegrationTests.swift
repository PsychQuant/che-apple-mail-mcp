import XCTest
@testable import MailSQLite

/// End-to-end tests for search_emails with new parameters (field, date_from, date_to).
/// These tests exercise the full SQLite query path against the real Envelope Index.
final class SearchIntegrationTests: XCTestCase {

    private var reader: EnvelopeIndexReader?

    override func setUpWithError() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }
        reader = try EnvelopeIndexReader(databasePath: path)
    }

    // MARK: - field parameter

    func testFieldSubjectOnlyMatchesSubject() throws {
        // Search for "gmail" in subject only — should NOT match sender addresses
        let results = try reader!.search(
            SearchParameters(query: "Re:", field: .subject, limit: 5)
        )
        for r in results {
            XCTAssertTrue(
                r.subject.localizedCaseInsensitiveContains("Re:"),
                "Subject-only search returned non-matching subject: '\(r.subject)'"
            )
        }
    }

    func testFieldSenderExcludesSubjectMatches() throws {
        // Search for a term that appears in subjects but not sender
        // Use "Re:" which commonly appears in subjects but not sender addresses
        let results = try reader!.search(
            SearchParameters(query: "Re:", field: .sender, limit: 5)
        )
        for r in results {
            let matchesSender = r.senderAddress.localizedCaseInsensitiveContains("Re:")
                || r.senderName.localizedCaseInsensitiveContains("Re:")
            XCTAssertTrue(matchesSender,
                "Sender-only search should only match sender, got: \(r.senderAddress) / \(r.senderName)")
        }
    }

    func testFieldRecipientSearches() throws {
        let results = try reader!.search(
            SearchParameters(query: "gmail", field: .recipient, limit: 5)
        )
        // Should execute without error — recipient search uses EXISTS subquery
        XCTAssertTrue(results.count >= 0)
    }

    func testFieldAnyIsDefault() throws {
        let explicitAny = try reader!.search(
            SearchParameters(query: "gmail", field: .any, limit: 10)
        )
        let defaultField = try reader!.search(
            SearchParameters(query: "gmail", limit: 10)
        )
        // Both should return the same results (default is .any)
        XCTAssertEqual(explicitAny.count, defaultField.count,
            "Explicit 'any' and default should return same count")
    }

    // MARK: - date_from / date_to parameters

    func testDateFromFiltersOldEmails() throws {
        let cutoff = ISO8601DateFormatter().date(from: "2026-03-01T00:00:00+08:00")!
        let results = try reader!.search(
            SearchParameters(query: "a", dateFrom: cutoff, limit: 20)
        )
        for r in results {
            XCTAssertGreaterThanOrEqual(r.dateReceived, cutoff,
                "date_from filter should exclude emails before \(cutoff)")
        }
    }

    func testDateToFiltersNewEmails() throws {
        let cutoff = ISO8601DateFormatter().date(from: "2025-06-01T00:00:00+08:00")!
        let results = try reader!.search(
            SearchParameters(query: "a", dateTo: cutoff, limit: 20)
        )
        for r in results {
            XCTAssertLessThanOrEqual(r.dateReceived, cutoff,
                "date_to filter should exclude emails after \(cutoff)")
        }
    }

    func testDateRangeCombined() throws {
        let from = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00+08:00")!
        let to = ISO8601DateFormatter().date(from: "2026-02-01T00:00:00+08:00")!
        let results = try reader!.search(
            SearchParameters(query: "a", dateFrom: from, dateTo: to, limit: 20)
        )
        for r in results {
            XCTAssertGreaterThanOrEqual(r.dateReceived, from)
            XCTAssertLessThanOrEqual(r.dateReceived, to)
        }
    }

    // MARK: - Combined parameters

    func testFieldWithDateRange() throws {
        let from = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00+08:00")!
        let results = try reader!.search(
            SearchParameters(query: "a", field: .subject, dateFrom: from, limit: 5)
        )
        for r in results {
            XCTAssertTrue(r.subject.localizedCaseInsensitiveContains("a"))
            XCTAssertGreaterThanOrEqual(r.dateReceived, from)
        }
    }

    func testToRecipientsPopulated() throws {
        let results = try reader!.search(SearchParameters(query: "a", limit: 10))
        let withTo = results.filter { !$0.toRecipients.isEmpty }
        XCTAssertFalse(withTo.isEmpty,
            "At least some results should have To recipients populated")
    }
}
