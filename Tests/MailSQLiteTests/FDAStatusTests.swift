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

    func testProbeUnreadableFileReportsDenied() throws {
        // A 000-perm file the owner can't read reproduces the EACCES/EPERM path
        // that distinguishes a genuine TCC denial from other errors. root
        // bypasses file perms, so skip there (CI/local run as the user).
        try XCTSkipIf(geteuid() == 0, "running as root bypasses file permissions")
        let tmp = NSTemporaryDirectory() + "fda-probe-noperm-\(ProcessInfo.processInfo.globallyUniqueString).bin"
        try Data([0x01]).write(to: URL(fileURLWithPath: tmp))
        XCTAssertEqual(chmod(tmp, 0), 0, "chmod 000 must succeed for the test to be meaningful")
        defer { _ = chmod(tmp, 0o644); try? FileManager.default.removeItem(atPath: tmp) }

        XCTAssertEqual(FDAStatus.probe(path: tmp), .denied,
                       "an unreadable (000) file is EACCES → .denied, not .undetermined")
    }

    func testSummaryDistinguishesAllFourStates() {
        XCTAssertTrue(FDAStatus.summary(.granted).contains("GRANTED"))
        XCTAssertTrue(FDAStatus.summary(.denied).contains("DENIED"))
        XCTAssertTrue(FDAStatus.summary(.noMailData).contains("UNKNOWN"))
        XCTAssertTrue(FDAStatus.summary(.undetermined).contains("UNDETERMINED"))
        // All four must be distinct so a reader (and check_fda) can tell them apart.
        let all = Set([
            FDAStatus.summary(.granted), FDAStatus.summary(.denied),
            FDAStatus.summary(.noMailData), FDAStatus.summary(.undetermined),
        ])
        XCTAssertEqual(all.count, 4)
    }

    func testDefaultProbePathIsTheEnvelopeIndex() {
        // The default path must be the real Envelope Index (not crash / empty).
        XCTAssertTrue(EnvelopeIndexReader.defaultDatabasePath.hasSuffix("MailData/Envelope Index"))
        // Probing it must not trap regardless of FDA state (returns some Probe).
        _ = FDAStatus.probe()
    }
}
