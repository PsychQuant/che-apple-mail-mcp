import XCTest
@testable import MailSQLite

final class StartupTests: XCTestCase {

    /// Verify EnvelopeIndexReader initializes quickly (no AppleScript blocking).
    /// AccountMapper.buildMapping() reads a plist synchronously — should be < 100ms.
    func testReaderInitializesWithinOneSecond() throws {
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }

        let start = CFAbsoluteTimeGetCurrent()
        let reader = try EnvelopeIndexReader(databasePath: path)
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
