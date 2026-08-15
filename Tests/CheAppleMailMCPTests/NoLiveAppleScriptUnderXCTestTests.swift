import XCTest
@testable import CheAppleMailMCP

/// #362 — the suite must never execute a real Apple Event.
///
/// Root cause of the instability this pins: `MailAppIntegrationTests.tearDown`
/// ran `cleanupIntegrationDrafts()` unconditionally. XCTest runs `tearDown`
/// even when `setUp` threw `XCTSkip`, so every ordinary `swift test` drove
/// **7 real AppleScript calls at the user's Mail.app** — ~135s of wall clock,
/// and, because `runGuarded` abandons its thread on timeout, a live AppleScript
/// event pump that collided with XCTest's run-loop observers and aborted the
/// process while blaming an unrelated test.
///
/// Two things are pinned here because the pair is what makes it safe: the
/// production guard refuses the real path under XCTest, and the escape hatch
/// keys on the **same** env var that already gates the live suite — so being
/// in live mode and being blocked cannot disagree.
final class NoLiveAppleScriptUnderXCTestTests: XCTestCase {

    func testGuardIsArmedInThisProcess() {
        XCTAssertTrue(MailController.isRunningUnderXCTest,
            "XCTest must be detectable — this whole guard hinges on it")
    }

    /// Default (no live env var) → the guard is active.
    func testEscapeHatchIsClosedByDefault() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MAIL_APP_INTEGRATION_TESTS"] != nil,
                      "running in live-integration mode — the hatch is open by design")
        XCTAssertFalse(MailController.liveAppleScriptAllowedInTests,
            "without MAIL_APP_INTEGRATION_TESTS the guard must block the real path")
    }

    /// The unseamed call fails FAST and names itself, rather than spawning a
    /// thread that outlives the test. Speed is the assertion: the pre-fix
    /// behavior was a 45s timeout followed by an abandoned live event pump.
    func testUnseamedCallFailsFastAndNamesTheProblem() async throws {
        try XCTSkipIf(MailController.liveAppleScriptAllowedInTests,
                      "live mode intentionally permits the real path")
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)

        let start = Date()
        do {
            _ = try await MailController.shared.getUnreadCount(mailbox: nil, accountName: nil, accountId: nil)
            XCTFail("an unseamed AppleScript call must not reach real Mail under XCTest")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 5.0,
                "must fail at the guard, not after runGuarded's timeout — the whole point is "
                + "that no thread is left running a live Apple Event (took \\(elapsed)s)")
            XCTAssertTrue(error.localizedDescription.contains("no test seam installed"),
                "the error must name the fix: \\(error.localizedDescription)")
        }
    }
}
