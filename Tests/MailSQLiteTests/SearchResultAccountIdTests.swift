import XCTest
@testable import MailSQLite

/// Tests for the `accountId` (UUID) field added to `SearchResult` for #101.
///
/// Two-tier coverage:
/// 1. **Structural** (hermetic, always runs): the field exists, is optional, round-trips
///    through `SearchResult` init + property access. Catches accidental field rename
///    or type change.
/// 2. **Integration** (XCTSkip if no real Envelope Index): a real `search(...)` call
///    populates `accountId` from `mailboxes.account_id` SQLite join. Asserts that
///    when account UUIDs are mapped, results carry the UUID alongside the display name.
final class SearchResultAccountIdTests: XCTestCase {

    // MARK: - Tier 1: Structural tests (hermetic)

    func testSearchResult_accountIdField_isOptionalString_andDefaultsToNil() {
        // Compile-time assertion: the field exists, is String?, and can be nil.
        // If someone deletes the field or changes its type, this won't compile.
        let result = SearchResult(
            id: 1,
            subject: "test",
            senderAddress: "a@b.com",
            senderName: "A",
            dateReceived: Date(timeIntervalSince1970: 0),
            accountName: "Alice",
            accountId: nil,
            mailboxPath: "INBOX",
            isRead: false,
            isFlagged: false,
            toRecipients: []
        )
        XCTAssertNil(result.accountId,
                     "accountId should be nil when explicitly passed nil")
    }

    func testSearchResult_accountIdField_acceptsUUIDString() {
        let uuid = "ABCD1234-5678-90AB-CDEF-1234567890AB"
        let result = SearchResult(
            id: 1,
            subject: "test",
            senderAddress: "a@b.com",
            senderName: "A",
            dateReceived: Date(timeIntervalSince1970: 0),
            accountName: "Alice",
            accountId: uuid,
            mailboxPath: "INBOX",
            isRead: false,
            isFlagged: false,
            toRecipients: []
        )
        XCTAssertEqual(result.accountId, uuid,
                       "accountId must round-trip the exact UUID string passed in")
    }

    // MARK: - Tier 2: Integration tests (real DB, XCTSkip-gated)

    func testSearch_populatesAccountIdFromMailboxesJoin() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available — integration test skipped")
        }
        let reader = try EnvelopeIndexReader(databasePath: path)
        let results = try reader.search(SearchParameters(query: "a", limit: 10))

        // At least one result with a non-empty accountName implies the
        // mailboxes JOIN ran successfully; the parallel accountId field
        // should be populated from the same row (UUID extracted from
        // the mailbox URL's authority).
        for r in results where !r.accountName.isEmpty {
            // If accountName resolved through AccountMapper, accountId should also be set.
            // If accountName fell back to the raw UUID (AccountMapper missing), accountId
            // should still match the UUID (they come from the same join).
            XCTAssertNotNil(r.accountId,
                            "Real Envelope Index search results MUST carry accountId "
                            + "(UUID from mailboxes.account_id join). Result with "
                            + "accountName='\(r.accountName)' had nil accountId — "
                            + "indicates the SQL join or SearchResult construction "
                            + "skipped the UUID population.")
            // UUID format check (loose): 36 chars with dashes
            if let aid = r.accountId {
                XCTAssertEqual(aid.count, 36,
                               "accountId='\(aid)' should be a 36-char UUID string")
            }
            return  // 1 successful assertion is enough; spare CI time
        }
        // If we got here, no result had a non-empty accountName — env is too sparse
        throw XCTSkip("No search results had non-empty accountName — cannot exercise the join")
    }
}
