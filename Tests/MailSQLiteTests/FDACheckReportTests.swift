import XCTest
@testable import MailSQLite

/// #537 — `check_fda` used to answer from a bare `fopen` probe and, on success,
/// promise the SQLite fast path "should now work" even when the server's own
/// reader had failed to open at startup and stayed nil. The report is now a
/// pure function of two facts: what the probe saw, and what the server's index
/// reader did when asked again. All 4 x 3 combinations are pinned here.
final class FDACheckReportTests: XCTestCase {

    private let probes: [FDAStatus.Probe] = [.granted, .denied, .noMailData, .undetermined]
    private let failure = "Failed to open database: authorization denied."

    private func outcomes() -> [IndexReaderProvider.RetryOutcome] {
        [.alreadyAvailable, .recovered(priorFailure: failure), .stillUnavailable(failure)]
    }

    // MARK: - granted

    func testGrantedWithOpenReaderSaysTheFastPathIsAvailableWithoutPromising() {
        let text = FDACheckReport.text(probe: .granted, index: .alreadyAvailable)
        XCTAssertTrue(text.contains("GRANTED"))
        XCTAssertTrue(text.contains("index reader is open"), "got: \(text)")
        XCTAssertFalse(text.contains("should now work"), "the old unconditional promise must be gone; got: \(text)")
    }

    func testGrantedAfterRecoveryNamesTheEarlierFailureAndTheTruncatedCaveat() {
        let text = FDACheckReport.text(probe: .granted, index: .recovered(priorFailure: failure))
        XCTAssertTrue(text.contains("✅"))
        XCTAssertTrue(text.contains("recovered"), "got: \(text)")
        XCTAssertTrue(text.contains(failure), "the failure it recovered from must be named; got: \(text)")
        XCTAssertTrue(text.contains("truncated"),
                      "SQLite and AppleScript decide `truncated` differently, so a recovery must say so; got: \(text)")
    }

    func testGrantedAfterRecoveryWithoutAPriorFailureStillReads() {
        let text = FDACheckReport.text(probe: .granted, index: .recovered(priorFailure: nil))
        XCTAssertTrue(text.contains("recovered"))
        XCTAssertFalse(text.contains("()"), "no empty parenthetical when there is no prior failure; got: \(text)")
    }

    func testGrantedButReaderStillUnavailableIsAWarningWithTheRealErrorAndTheFix() {
        let text = FDACheckReport.text(probe: .granted, index: .stillUnavailable(failure))
        XCTAssertTrue(text.contains("⚠️"))
        XCTAssertFalse(text.contains("✅"))
        XCTAssertTrue(text.contains(failure), "the server's own open error must be shown; got: \(text)")
        XCTAssertTrue(text.contains("/mcp"), "the fix is to reconnect the server; got: \(text)")
        XCTAssertFalse(text.contains("should now work"))
    }

    func testOnlyTheFirstLineOfAMultilineFailureIsShown() {
        let multiline = "Failed to open database: authorization denied.\nApple Mail's Envelope Index requires Full Disk Access."
        let text = FDACheckReport.text(probe: .granted, index: .stillUnavailable(multiline))
        XCTAssertTrue(text.contains("Failed to open database: authorization denied."))
        XCTAssertFalse(text.contains("requires Full Disk Access"),
                       "granted + failed open must not re-print the grant instructions the probe just contradicted; got: \(text)")
    }

    // MARK: - not granted: existing wording stays, reader state is appended

    func testDeniedKeepsTheGrantGuidance() {
        for outcome in outcomes() {
            let text = FDACheckReport.text(probe: .denied, index: outcome)
            XCTAssertTrue(text.contains("DENIED"))
            XCTAssertTrue(text.contains("Privacy_AllFiles"), "denied keeps the settings deep link for \(outcome); got: \(text)")
        }
    }

    func testNoMailDataKeepsBothPossibilities() {
        for outcome in outcomes() {
            let text = FDACheckReport.text(probe: .noMailData, index: outcome)
            XCTAssertTrue(text.contains("UNKNOWN"))
            XCTAssertTrue(text.contains("If Mail genuinely isn't set up"), "got: \(text)")
        }
    }

    func testUndeterminedKeepsTheRetryAdvice() {
        for outcome in outcomes() {
            let text = FDACheckReport.text(probe: .undetermined, index: outcome)
            XCTAssertTrue(text.contains("UNDETERMINED"))
            XCTAssertTrue(text.contains("retry first"), "got: \(text)")
        }
    }

    func testProbeAndReaderDisagreeingInTheOtherDirectionIsStated() {
        for probe in [FDAStatus.Probe.denied, .noMailData, .undetermined] {
            for outcome in [IndexReaderProvider.RetryOutcome.alreadyAvailable, .recovered(priorFailure: nil)] {
                let text = FDACheckReport.text(probe: probe, index: outcome)
                XCTAssertTrue(text.contains("index reader is open"),
                              "probe \(probe) but an open reader must be reported; got: \(text)")
            }
            let text = FDACheckReport.text(probe: probe, index: .stillUnavailable(failure))
            XCTAssertTrue(text.contains(failure), "probe \(probe): the reader's own error must be shown; got: \(text)")
        }
    }

    // MARK: - the whole matrix

    func testNoCellEverPromisesTheFastPathUnconditionally() {
        for probe in probes {
            for outcome in outcomes() {
                let text = FDACheckReport.text(probe: probe, index: outcome)
                XCTAssertFalse(text.isEmpty, "\(probe) x \(outcome) produced nothing")
                XCTAssertTrue(text.contains(FDAStatus.summary(probe)), "\(probe) x \(outcome) lost the probe summary; got: \(text)")
                XCTAssertFalse(text.contains("should now work"), "\(probe) x \(outcome) still says 'should now work'")
            }
        }
    }
}
