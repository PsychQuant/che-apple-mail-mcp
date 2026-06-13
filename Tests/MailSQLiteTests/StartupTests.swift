import XCTest
@testable import MailSQLite

final class StartupTests: XCTestCase {

    /// Verify EnvelopeIndexReader initializes quickly (no AppleScript blocking).
    /// AccountMapper.buildMapping() reads a plist synchronously — should be < 100ms.
    func testReaderInitializesWithinOneSecond() throws {
        // #182: this test deliberately measures the FIRST (cold) init to catch
        // AppleScript leaking into the init path or a slow plist read. It must
        // therefore NOT route through realEnvelopeIndexPathOrSkip() — that probe
        // would open the DB first and warm caches, turning the timed init into a
        // warm-path near-tautology (verify PR #188 finding). Guard on existence
        // only, then let the timed construction itself surface FDA denial as a
        // skip, keeping the measured init genuinely cold.
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }

        let start = CFAbsoluteTimeGetCurrent()
        let reader: EnvelopeIndexReader
        do {
            reader = try EnvelopeIndexReader(databasePath: path)
        } catch let error as MailSQLiteError {
            if case .databaseNotAccessible = error {
                throw XCTSkip("Envelope Index not openable (likely missing Full Disk Access) — #182")
            }
            throw error
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertNotNil(reader)
        XCTAssertLessThan(elapsed, 1.0,
            "Init should complete within 1 second (was \(elapsed)s). "
            + "If this fails, AppleScript may be leaking into the init path.")
    }

    /// Verify AccountMapper.buildMapping() is synchronous and fast.
    func testAccountMapperBuildMappingIsFast() {
        let start = CFAbsoluteTimeGetCurrent()
        let mapping = AccountMapper.buildMapping()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.1,
            "AccountMapper should read plist in < 100ms (was \(elapsed)s)")
        // Mapping may be empty if plist doesn't exist — that's OK
    }
}
