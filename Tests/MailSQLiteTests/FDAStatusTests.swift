import XCTest
@testable import MailSQLite

/// #213 — the functional FDA probe is the only honest signal for Full Disk
/// Access (no query API exists). These tests pin the readable / missing-file
/// branches; the TCC-refused (`.denied`) branch can't be exercised without a
/// real denied grant, but the `errno` discrimination is covered by the missing
/// vs readable cases.
final class FDAStatusTests: XCTestCase {

    func testProbeReadableFileReportsGranted() throws {
        // A file we can definitely open stands in for a readable Envelope Index.
        let tmp = NSTemporaryDirectory() + "fda-probe-\(ProcessInfo.processInfo.globallyUniqueString).bin"
        try Data([0x01, 0x02, 0x03]).write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        XCTAssertEqual(FDAStatus.probe(path: tmp), .granted,
                       "a readable file must probe as .granted")
    }

    func testProbeMissingFileReportsNoMailData() {
        let missing = NSTemporaryDirectory() + "fda-probe-does-not-exist-\(ProcessInfo.processInfo.globallyUniqueString)"
        XCTAssertEqual(FDAStatus.probe(path: missing), .noMailData,
                       "a nonexistent path is ENOENT → .noMailData, not .denied")
    }

    func testSummaryDistinguishesAllThreeStates() {
        XCTAssertTrue(FDAStatus.summary(.granted).contains("GRANTED"))
        XCTAssertTrue(FDAStatus.summary(.denied).contains("DENIED"))
        XCTAssertTrue(FDAStatus.summary(.noMailData).contains("UNKNOWN"))
        // All three must be distinct so a reader can tell them apart.
        let all = Set([FDAStatus.summary(.granted), FDAStatus.summary(.denied), FDAStatus.summary(.noMailData)])
        XCTAssertEqual(all.count, 3)
    }

    func testDefaultProbePathIsTheEnvelopeIndex() {
        // The default path must be the real Envelope Index (not crash / empty).
        XCTAssertTrue(EnvelopeIndexReader.defaultDatabasePath.hasSuffix("MailData/Envelope Index"))
        // Probing it must not trap regardless of FDA state (returns some Probe).
        _ = FDAStatus.probe()
    }
}
