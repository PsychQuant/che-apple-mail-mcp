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
        // The leading `-`/`+` cases were MISSING from this list, which is why
        // the suite could not see #303 verify finding #4 (a leading separator
        // was swallowed by split's omittingEmptySubsequences, so "-1.2.3"
        // parsed as 1.2.3 and could raise a spurious nag).
        for garbage in ["abc", "2.25", "2.25.0.1", "", "v2.26.0", "latest", "2.x.0",
                        "-1.2.3", "+2.0.0", "-99.0.0", "+99.0.0", "-0.0.1"] {
            XCTAssertNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: garbage),
                         "unparseable sidecar '\(garbage)' must fail open (no warning)")
        }
    }

    func testSemVer_rejectsLeadingSeparator() {
        XCTAssertNil(SemVer("-1.2.3"), "a leading '-' is malformed, not a suffix")
        XCTAssertNil(SemVer("+2.0.0"), "a leading '+' is malformed, not a suffix")
        // ...while a genuine suffix is still discarded as documented.
        XCTAssertEqual(SemVer("2.0.0-rc1")?.minor, 0)
        XCTAssertNotNil(SemVer("2.0.0+build7"))
    }

    // MARK: - #303 verify #3: the warning carries parsed ints, never raw bytes

    func testWarning_neverEchoesRawSidecarBytes() {
        let payload = "2.26.0-\u{1B}[2J\u{1B}[H[stderr] FORGED: everything is fine\nsecond line"
        let warning = StalenessCheck.evaluate(compiled: "2.25.0", sidecar: payload)

        XCTAssertNotNil(warning, "the 2.26.0 prefix is real drift — it should still warn")
        XCTAssertFalse(warning?.contains("FORGED") == true,
                       "raw sidecar content must never reach the warning (log forging)")
        XCTAssertFalse(warning?.contains("\u{1B}") == true,
                       "no ANSI escape may reach stderr — it lands in MCP logs people tail -f")
        XCTAssertFalse(warning?.contains("\n") == true,
                       "no embedded newline — one warning must stay one log line")
        XCTAssertTrue(warning?.contains("2.26.0") == true,
                      "the parsed version is still reported")
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

    func testGate_warnsOnce_thenStopsReading() {
        var state = false
        var reads = 0
        let reader: () -> String? = { reads += 1; return "99.0.0" }  // always drift vs any real compiled

        let first = MailController.stalenessWarningOnce(state: &state, reader: reader)
        XCTAssertNotNil(first, "first call must surface the drift warning")
        XCTAssertTrue(state, "gate is consumed once a warning has actually been emitted")
        XCTAssertEqual(reads, 1)

        let second = MailController.stalenessWarningOnce(state: &state, reader: reader)
        XCTAssertNil(second, "already warned — do not nag every call")
        XCTAssertEqual(reads, 1, "and do not keep re-reading once the point has been made")
    }

    // MARK: - B2 regression (#303 verify): warn-once, NOT check-once

    /// The predecessor of this test asserted that a no-drift check consumed the
    /// gate — locking in the defect and persuading three independent reviewers
    /// it was intended. The gate must stay ARMED until it has something to say.
    func testGate_noDrift_leavesGateArmedAndKeepsChecking() {
        var state = false
        var reads = 0
        let reader: () -> String? = { reads += 1; return nil }  // fail-open, no sidecar

        XCTAssertNil(MailController.stalenessWarningOnce(state: &state, reader: reader))
        XCTAssertFalse(state, "a no-warning check must NOT consume the gate")
        XCTAssertEqual(reads, 1)

        XCTAssertNil(MailController.stalenessWarningOnce(state: &state, reader: reader))
        XCTAssertEqual(reads, 2, "still armed → still checking on the next call")
    }

    /// The production sequence: `Server.swift`'s startup `checkForNewMail()`
    /// reaches `preflightAutomation()` before the transport starts, when the
    /// sidecar necessarily matches the running binary. Hours later another
    /// window's wrapper installs a newer binary. That drift must still surface.
    func testStartupNoDrift_thenLaterDrift_stillWarns() {
        var state = false
        var sidecar = AppVersion.current
        let reader: () -> String? = { sidecar }

        XCTAssertNil(MailController.stalenessWarningOnce(state: &state, reader: reader),
                     "no drift at startup — correct to stay silent")

        sidecar = "99.0.0"   // a newer binary lands on disk mid-session

        XCTAssertNotNil(MailController.stalenessWarningOnce(state: &state, reader: reader),
            "drift after a no-drift startup must still warn — this is the whole "
            + "long-lived-window scenario #303 exists for")
    }
}
