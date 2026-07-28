import XCTest
@testable import CheAppleMailMCP

/// #303 — the pure staleness comparison. The filesystem read + one-time gate
/// (preflightAutomation wiring) are the thin live layer; this locks the logic.
final class StalenessCheckTests: XCTestCase {

    func testDrift_onDiskNewer_warnsNamingBothVersions() {
        let w = StalenessCheck.evaluate(compiled: "2.25.0", sidecar: "2.26.0")
        XCTAssertNotNil(w)
        XCTAssertTrue(w?.contains("2.25.0") == true, "warning must name the running (stale) version")
        XCTAssertTrue(w?.contains("2.26.0") == true, "warning must name the installed (newer) version")
        XCTAssertTrue(w?.lowercased().contains("restart") == true, "warning must be actionable (restart)")
    }

    func testEqual_noWarning() {
        XCTAssertNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: "2.25.0"))
    }

    func testOnDiskOlder_noWarning_runningImageIsAhead() {
        // The running binary is NEWER than the sidecar (e.g. a fresh build not
        // yet reflected in the sidecar) — never nag in that direction.
        XCTAssertNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: "2.24.0"))
    }

    func testSidecarNil_failOpen() {
        // No sidecar (dev build from .build/, or non-plugin install) → silent.
        XCTAssertNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: nil))
    }

    func testUnparseableSidecar_failOpen() {
        for garbage in ["abc", "2.25", "2.25.0.1", "", "v2.26.0", "latest", "2.x.0"] {
            XCTAssertNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: garbage),
                         "unparseable sidecar '\(garbage)' must fail open (no warning)")
        }
    }

    func testUnparseableCompiled_failOpen() {
        XCTAssertNil(StalenessCheck.evaluate(compiled: "dev", sidecar: "2.26.0"))
    }

    func testMajorMinorPatchOrdering() {
        XCTAssertNotNil(StalenessCheck.evaluate(compiled: "1.0.0", sidecar: "2.0.0"))   // major
        XCTAssertNotNil(StalenessCheck.evaluate(compiled: "2.9.0", sidecar: "2.10.0"))  // minor (not string-compared)
        XCTAssertNotNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: "2.25.1")) // patch
        XCTAssertNil(StalenessCheck.evaluate(compiled: "2.10.0", sidecar: "2.9.0"))     // 10 > 9 numerically
    }

    func testSemVer_ignoresPrereleaseAndBuildSuffix() {
        XCTAssertNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: "2.25.0-dev"))  // same core → no drift
        XCTAssertNotNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: "2.26.0+ci")) // core 2.26.0 > 2.25.0
    }

    // MARK: - one-time gate (the preflightAutomation seam)

    func testGate_firesOnceAndDoesNotReReadAfter() {
        var state = false
        var reads = 0
        let reader: () -> String? = { reads += 1; return "99.0.0" }  // always drift vs any real compiled

        let first = MailController.stalenessWarningOnce(state: &state, reader: reader)
        XCTAssertNotNil(first, "first call must surface the drift warning")
        XCTAssertTrue(state, "gate must flip so subsequent calls short-circuit")
        XCTAssertEqual(reads, 1)

        let second = MailController.stalenessWarningOnce(state: &state, reader: reader)
        XCTAssertNil(second, "second call must short-circuit — staleness surfaces once per process")
        XCTAssertEqual(reads, 1, "gate must NOT re-read the sidecar off the hot path after the first check")
    }

    func testGate_noDrift_stillFlipsAndStopsReading() {
        var state = false
        var reads = 0
        let reader: () -> String? = { reads += 1; return nil }  // fail-open, no sidecar

        XCTAssertNil(MailController.stalenessWarningOnce(state: &state, reader: reader))
        XCTAssertTrue(state, "even a no-warning check consumes the one-time gate")
        XCTAssertEqual(reads, 1)

        XCTAssertNil(MailController.stalenessWarningOnce(state: &state, reader: reader))
        XCTAssertEqual(reads, 1, "no second read even when the first found nothing")
    }
}
