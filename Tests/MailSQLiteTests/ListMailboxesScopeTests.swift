import XCTest
@testable import MailSQLite

/// #202: `listMailboxes(accountName:accountId:)` must scope by account and
/// **throw** on an unresolvable name instead of silently returning every
/// account's mailboxes. FDA-gated (needs the real Envelope Index) — skipped in
/// the default `swift test` / CI run.
final class ListMailboxesScopeTests: XCTestCase {

    private func makeReader() throws -> EnvelopeIndexReader {
        let dbPath = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Envelope Index not available (no Full Disk Access)")
        }
        do { return try EnvelopeIndexReader(databasePath: dbPath) }
        catch { throw XCTSkip("Could not open Envelope Index: \(error)") }
    }

    /// An `account_name` that resolves to no configured account throws
    /// `accountNotResolvable` — never the old return-all-unscoped result.
    func testUnresolvableAccountName_throws() throws {
        let reader = try makeReader()
        XCTAssertThrowsError(
            try reader.listMailboxes(accountName: "idd202-no-such-account-\(UUID().uuidString)")
        ) { error in
            guard case MailSQLiteError.accountNotResolvable = error else {
                return XCTFail("expected accountNotResolvable, got \(error)")
            }
        }
    }

    /// A non-empty `accountId` scopes the result to that account only — and the
    /// scoped set is a subset of the unscoped "list all" set.
    func testAccountIdScopesToThatAccount() throws {
        let reader = try makeReader()
        let accounts = reader.listAccounts()
        guard let acct = accounts.first,
              let uuid = acct["id"] as? String, !uuid.isEmpty,
              let acctName = acct["name"] as? String else {
            throw XCTSkip("No accounts in the Envelope Index")
        }

        let scoped = try reader.listMailboxes(accountId: uuid)
        let all = try reader.listMailboxes()   // no selector → every mailbox

        XCTAssertLessThanOrEqual(scoped.count, all.count,
                                 "an account-scoped list can't exceed the full list")
        for box in scoped {
            XCTAssertEqual(box["account_name"] as? String, acctName,
                           "accountId scope must return only that account's mailboxes")
        }
    }
}
