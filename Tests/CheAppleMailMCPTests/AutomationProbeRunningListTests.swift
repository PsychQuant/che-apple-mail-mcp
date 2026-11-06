import XCTest
import CoreServices
@testable import CheAppleMailMCP

/// #499 — `NSRunningApplication` can come back empty for a Mail that is
/// running (seen under load, 1–4 runs in 33). The probe used to return
/// `.targetNotRunning` on that alone, which `preflightAutomation` turns into
/// "Mail is not running" for every GUI-path call. These tests drive the probe's
/// decision table through an injected environment; no Mail is involved.
final class AutomationProbeRunningListTests: XCTestCase {

    /// Scripted environment: `running` is consumed one value per list read
    /// (the last value repeats), `status` is the Apple Event answer.
    private final class Script {
        var running: [Bool]
        let status: OSStatus
        var listReads = 0
        var permissionReads = 0
        var sleeps: [TimeInterval] = []
        var logs: [String] = []
        init(running: [Bool], status: OSStatus) { self.running = running; self.status = status }

        var environment: AutomationStatus.Environment {
            AutomationStatus.Environment(
                isRunning: { _ in
                    defer { self.listReads += 1 }
                    return self.running[min(self.listReads, self.running.count - 1)]
                },
                determinePermission: { _ in self.permissionReads += 1; return self.status },
                sleep: { self.sleeps.append($0) },
                log: { self.logs.append($0) })
        }
    }

    func testListedAndGrantedIsGrantedWithoutWaiting() {
        let s = Script(running: [true], status: noErr)
        XCTAssertEqual(AutomationStatus.probe(environment: s.environment), .granted)
        XCTAssertEqual(s.sleeps, [])
        XCTAssertEqual(s.logs, [])
    }

    func testEmptyListThenRunningReportsTheAppleEventAnswer() {
        let s = Script(running: [false, true], status: noErr)
        XCTAssertEqual(AutomationStatus.probe(environment: s.environment), .granted,
                       "a transiently empty list must not become 'Mail is not running'")
        XCTAssertEqual(s.sleeps, [AutomationStatus.runningListRecheckInterval])
        XCTAssertEqual(s.logs.count, 1, "a recovery is logged so the server's rate is observable")
        XCTAssertTrue(s.logs[0].contains("#499"))
    }

    func testEmptyListThenRunningKeepsADenial() {
        let s = Script(running: [false, false, true], status: OSStatus(errAEEventNotPermitted))
        XCTAssertEqual(AutomationStatus.probe(environment: s.environment), .denied)
        XCTAssertEqual(s.sleeps.count, 2)
    }

    func testAListThatStaysEmptyIsNotRunningWithoutAskingAppleEvents() {
        // The probe must not have side effects: a closed Mail gets no Apple
        // Event work at all, exactly as before #499. It would answer `.granted`
        // here if it were asked, so this also proves it was not consulted.
        let s = Script(running: [false], status: noErr)
        XCTAssertEqual(AutomationStatus.probe(environment: s.environment), .targetNotRunning)
        XCTAssertEqual(s.permissionReads, 0)
        XCTAssertEqual(s.sleeps, Array(repeating: AutomationStatus.runningListRecheckInterval,
                                       count: AutomationStatus.runningListRechecks))
        XCTAssertEqual(s.listReads, 1 + AutomationStatus.runningListRechecks)
        XCTAssertEqual(s.logs, [], "a closed Mail is the ordinary case, not a disagreement")
    }

    func testAMailThatQuitsBetweenTheListAndTheCheckIsNotRunning() {
        let s = Script(running: [true], status: OSStatus(procNotFound))
        XCTAssertEqual(AutomationStatus.probe(environment: s.environment), .targetNotRunning)
        XCTAssertEqual(s.sleeps, [])
    }

    func testAnAddressErrorStaysUnknown() {
        let s = Script(running: [true], status: -1701)
        XCTAssertEqual(AutomationStatus.probe(environment: s.environment), .unknown(-1701))
    }

    func testWorstCaseWaitIsBounded() {
        XCTAssertLessThanOrEqual(
            Double(AutomationStatus.runningListRechecks) * AutomationStatus.runningListRecheckInterval, 0.5)
    }

    func testStatusMappingIsUnchanged() {
        XCTAssertEqual(AutomationStatus.state(for: noErr), .granted)
        XCTAssertEqual(AutomationStatus.state(for: OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(AutomationStatus.state(for: -1744), .notDetermined)
        XCTAssertEqual(AutomationStatus.state(for: OSStatus(procNotFound)), .targetNotRunning)
        XCTAssertEqual(AutomationStatus.state(for: -50), .unknown(-50))
    }

    func testTheAppleEventCheckRunsOncePerProbe() {
        let s = Script(running: [false, false, true], status: noErr)
        _ = AutomationStatus.probe(environment: s.environment)
        XCTAssertEqual(s.permissionReads, 1)
    }
}
