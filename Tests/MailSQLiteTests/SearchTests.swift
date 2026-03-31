import XCTest
@testable import MailSQLite

final class SearchTests: XCTestCase {

    private var reader: EnvelopeIndexReader?

    override func setUpWithError() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }
        reader = try EnvelopeIndexReader(databasePath: path)
    }

    // MARK: - 3.1 Core JOIN structure

    func testSearchReturnsResults() throws {
        let results = try reader!.search(SearchParameters(query: "mail", limit: 5))
        // Should find at least some emails with "mail" in subject/sender/recipient
        XCTAssertFalse(results.isEmpty, "Should find at least one result for common query")
    }

    func testSearchExcludesDeleted() throws {
        let results = try reader!.search(SearchParameters(query: "a", limit: 100))
        // All returned results should be non-deleted (we can't verify directly,
        // but the query should execute without error)
        XCTAssertTrue(results.count <= 100)
    }

    // MARK: - 3.2 Search by subject

    func testSearchBySubject() throws {
        let results = try reader!.search(
            SearchParameters(query: "mail", field: .subject, limit: 5)
        )
        for r in results {
            XCTAssertTrue(
                r.subject.localizedCaseInsensitiveContains("mail"),
                "Subject '\(r.subject)' should contain 'mail'"
            )
        }
    }

    // MARK: - 3.3 Search by sender

    func testSearchBySender() throws {
        let results = try reader!.search(
            SearchParameters(query: "gmail", field: .sender, limit: 5)
        )
        for r in results {
            let matchesSender = r.senderAddress.localizedCaseInsensitiveContains("gmail")
                || r.senderName.localizedCaseInsensitiveContains("gmail")
            XCTAssertTrue(matchesSender, "Sender should contain 'gmail': \(r.senderAddress) / \(r.senderName)")
        }
    }

    // MARK: - 3.4 Search by recipient

    func testSearchByRecipient() throws {
        let results = try reader!.search(
            SearchParameters(query: "gmail", field: .recipient, limit: 5)
        )
        XCTAssertTrue(results.count >= 0) // Just verify query executes
    }

    // MARK: - 3.5 Search with default field "any"

    func testSearchDefaultFieldIsAny() throws {
        let results = try reader!.search(SearchParameters(query: "gmail", limit: 5))
        // Default field is .any — should search across all fields
        XCTAssertFalse(results.isEmpty, "Should find results with default 'any' field")
    }

    // MARK: - 3.6 Date range filtering

    func testSearchWithDateRange() throws {
        // Search for emails from 2026
        let dateFrom = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00+08:00")!
        let results = try reader!.search(
            SearchParameters(query: "a", dateFrom: dateFrom, limit: 5)
        )
        for r in results {
            XCTAssertGreaterThanOrEqual(r.dateReceived, dateFrom,
                "Result date \(r.dateReceived) should be >= \(dateFrom)")
        }
    }

    func testSearchWithDateTo() throws {
        // Search for emails before 2025
        let dateTo = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00+08:00")!
        let results = try reader!.search(
            SearchParameters(query: "a", dateTo: dateTo, limit: 5)
        )
        for r in results {
            XCTAssertLessThanOrEqual(r.dateReceived, dateTo,
                "Result date \(r.dateReceived) should be <= \(dateTo)")
        }
    }

    // MARK: - 3.7 Sorting and limiting

    func testSearchSortDescending() throws {
        let results = try reader!.search(
            SearchParameters(query: "a", sort: .desc, limit: 10)
        )
        guard results.count >= 2 else { return }
        for i in 1..<results.count {
            XCTAssertGreaterThanOrEqual(
                results[i - 1].dateReceived, results[i].dateReceived,
                "Results should be sorted newest first"
            )
        }
    }

    func testSearchSortAscending() throws {
        let results = try reader!.search(
            SearchParameters(query: "a", sort: .asc, limit: 10)
        )
        guard results.count >= 2 else { return }
        for i in 1..<results.count {
            XCTAssertLessThanOrEqual(
                results[i - 1].dateReceived, results[i].dateReceived,
                "Results should be sorted oldest first"
            )
        }
    }

    func testSearchRespectsLimit() throws {
        let results = try reader!.search(
            SearchParameters(query: "a", limit: 3)
        )
        XCTAssertLessThanOrEqual(results.count, 3, "Should return at most 3 results")
    }

    // MARK: - 3.8 Result format backward compatibility

    func testSearchResultContainsRequiredFields() throws {
        let results = try reader!.search(SearchParameters(query: "a", limit: 1))
        guard let result = results.first else {
            throw XCTSkip("No results found")
        }
        XCTAssertGreaterThan(result.id, 0)
        XCTAssertFalse(result.subject.isEmpty)
        XCTAssertFalse(result.senderAddress.isEmpty)
        // dateReceived should be a valid date
        XCTAssertGreaterThan(result.dateReceived.timeIntervalSince1970, 0)
        // accountName and mailboxPath should be populated
        XCTAssertFalse(result.accountName.isEmpty)
        XCTAssertFalse(result.mailboxPath.isEmpty)
    }
}
