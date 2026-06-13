import XCTest
import SQLite3
@testable import MailSQLite

/// Shared gate for tests that exercise the **real** Apple Mail Envelope Index
/// store (#182).
///
/// Background: the live-store tests historically guarded with a bare
/// `FileManager.default.fileExists(atPath:)` check and `throw XCTSkip(...)`.
/// That is insufficient under **missing Full Disk Access**: the
/// `Envelope Index` file is still *statable* (so `fileExists` returns true and
/// the guard passes), but the SQLite open then fails and
/// `EnvelopeIndexReader.init` throws `MailSQLiteError.databaseNotAccessible` —
/// which escapes the test as an `XCTFail`. On any FDA-denied shell (CI,
/// background jobs, fresh machines) this produced ~42 spurious failures
/// indistinguishable from a real regression.
///
/// This gate replaces the bare existence check with an **openability probe at
/// the raw `sqlite3_open_v2` level** (verify PR #188 review):
///
///   - It deliberately does **not** construct the production
///     `EnvelopeIndexReader`. That avoids two defects of a reader-based probe:
///     (a) warming `AccountMapper`/plist/reverse-index/page caches ahead of a
///     timing-sensitive test (see `StartupTests`, which keeps its own cold
///     guard), and (b) masking a genuine production-init regression — since the
///     gate never runs init, any init regression always surfaces in the
///     caller's own `EnvelopeIndexReader(databasePath:)` rather than being
///     swallowed as a skip.
///   - It skips **only** on the SQLite result codes an FDA / OS-permission
///     denial produces (`SQLITE_CANTOPEN` / `SQLITE_PERM` / `SQLITE_AUTH`). Any
///     other open failure (e.g. a corrupt-but-present DB → `SQLITE_NOTADB`) does
///     NOT skip: the path is returned so the caller's real construction surfaces
///     the error as a true failure.
///
/// Mirrors the env-gated `XCTSkip` convention already used by
/// `MailAppIntegrationTests`.
extension XCTestCase {
    /// Returns the real Envelope Index path, or throws `XCTSkip` when the store
    /// is missing **or** the OS denies opening it (the missing-Full-Disk-Access
    /// case). Use this instead of a bare `fileExists` guard for tests that
    /// construct `EnvelopeIndexReader(databasePath:)` against the live store —
    /// **except** tests that must measure a cold first open (e.g.
    /// `StartupTests.testReaderInitializesWithinOneSecond`), which guard
    /// themselves so this probe does not warm caches ahead of their timing.
    func realEnvelopeIndexPathOrSkip(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available at \(path)")
        }
        // Raw read-only open probe — does NOT build the production reader.
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        if handle != nil { sqlite3_close(handle) }
        if rc != SQLITE_OK {
            let primary = rc & 0xFF
            if primary == SQLITE_CANTOPEN || primary == SQLITE_PERM || primary == SQLITE_AUTH {
                throw XCTSkip(
                    "Envelope Index exists but the OS denied opening it "
                    + "(sqlite rc \(rc)) — likely missing Full Disk Access (#182)."
                )
            }
            // Any other open failure is NOT an environment skip — fall through
            // and return the path so the caller's real EnvelopeIndexReader
            // construction surfaces the error (a genuine regression must fail).
        }
        return path
    }
}
