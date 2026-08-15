import XCTest
@testable import CheAppleMailMCP

/// #297 — the AppleScript execution path (`runScript` / `runScriptAsList`)
/// must be bounded by a wall-clock timeout: a runner that never returns has to
/// surface `MailError.scriptTimedOut` within the deadline, not block forever
/// (which used to wedge the request thread until the MCP client's ~120s idle
/// timeout dropped the whole server connection).
///
/// The timeout guard is exercised through the `scriptRunnerOverride` test seam
/// (no live NSAppleScript / Mail required); the seam is routed through the same
/// guard as the real path, so this also covers `runScriptAsList`.
final class MailControllerTimeoutTests: XCTestCase {

    override func tearDown() async throws {
        // Shared singleton actor — reset the seams so other suites are unaffected.
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    func testRunScript_hangingRunner_throwsScriptTimedOutWithinDeadline() async throws {
        let controller = MailController.shared
        await controller.setTestSeams(
            scriptRunner: { _ in
                Thread.sleep(forTimeInterval: 5.0)   // >> the 0.5s deadline below
                return "should never be returned"
            },
            refusal: nil,
            scriptTimeout: 0.5
        )

        let start = Date()
        do {
            _ = try await controller.runScript("dummy")
            XCTFail("expected .scriptTimedOut, got a value")
        } catch let error as MailError {
            guard case .scriptTimedOut = error else {
                return XCTFail("expected .scriptTimedOut, got \(error)")
            }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(
                elapsed, 3.0,
                "guard must return near the 0.5s deadline, not wait for the 5s runner")
            // Actionable message carries the remediation guidance.
            XCTAssertTrue(
                error.errorDescription?.contains("Automation") ?? false,
                "timeout error should surface the Automation-TCC guidance")
        }
    }

    func testRunScript_fastRunner_returnsValueWithoutFalseTimeout() async throws {
        let controller = MailController.shared
        await controller.setTestSeams(
            scriptRunner: { _ in "ok" },
            refusal: nil,
            scriptTimeout: 5.0
        )
        let value = try await controller.runScript("dummy")
        XCTAssertEqual(value, "ok")
    }

    func testRunScript_runnerThrows_propagatesUnderlyingError() async throws {
        struct Boom: Error {}
        let controller = MailController.shared
        await controller.setTestSeams(
            scriptRunner: { _ in throw Boom() },
            refusal: nil,
            scriptTimeout: 5.0
        )
        do {
            _ = try await controller.runScript("dummy")
            XCTFail("expected the runner's error to propagate")
        } catch is Boom {
            // expected — the guard rethrows the body's error, not a timeout
        }
    }
}
