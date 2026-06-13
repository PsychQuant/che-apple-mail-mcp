import XCTest
@testable import MailSQLite

/// Shared gate for tests that exercise the **real** Apple Mail Envelope Index
/// store (#182).
///
/// Background: the live-store tests historically guarded with a bare
/// `FileManager.default.fileExists(atPath:)` check and `throw XCTSkip(...)`.
/// That is insufficient under **missing Full Disk Access**: the
/// `Envelope Index` file is still *statable* (so `fileExists` returns true and
/// the guard passes), but `sqlite3_open_v2` then returns an authorization
/// error and `EnvelopeIndexReader.init` throws
/// `MailSQLiteError.databaseNotAccessible` — which escapes the test as an
/// `XCTFail`. On any FDA-denied shell (CI, background jobs, fresh machines)
/// this produced ~42 spurious failures indistinguishable from a real
/// regression.
///
/// This gate replaces the bare existence check: it proves the store is
/// actually *openable*, converting both "missing" and "exists-but-unopenable"
/// into a clean `XCTSkip`. A genuine non-FDA `MailSQLiteError` (e.g. a
/// corrupt-but-readable DB) still surfaces as a real failure.
///
/// Mirrors the env-gated `XCTSkip` convention already used by
/// `MailAppIntegrationTests`.
extension XCTestCase {
    /// Returns the real Envelope Index path, or throws `XCTSkip` when the store
    /// is missing **or** exists but cannot be opened (the missing-Full-Disk-Access
    /// case). Use this instead of a bare `fileExists` guard for any test that
    /// constructs `EnvelopeIndexReader(databasePath:)` against the live store.
    func realEnvelopeIndexPathOrSkip() throws -> String {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available at \(path)")
        }
        // FDA case: the file exists but the SQLite open is authorization-denied.
        // Prove openability here so the databaseNotAccessible throw becomes a
        // skip rather than escaping a downstream construction as XCTFail.
        do {
            _ = try EnvelopeIndexReader(databasePath: path)  // deinit closes the handle
        } catch let error as MailSQLiteError {
            if case .databaseNotAccessible(let message) = error {
                throw XCTSkip(
                    "Envelope Index exists but is not openable — likely missing "
                    + "Full Disk Access (#182). Underlying: \(message)"
                )
            }
            throw error  // a different MailSQLiteError is a real failure — surface it
        }
        return path
    }
}
