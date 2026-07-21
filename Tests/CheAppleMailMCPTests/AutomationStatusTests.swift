import XCTest
import MCP
@testable import CheAppleMailMCP

/// #293 — check_automation: the pure state → report mapping (the probe itself
/// is the thin live layer, attended residue). Modeled on the check_fda /
/// check_accessibility precedent; the third TCC axis.
final class AutomationStatusTests: XCTestCase {

    func testReport_granted_positive() {
        let r = AutomationStatus.report(for: .granted)
        XCTAssertTrue(r.contains("GRANTED"))
        XCTAssertTrue(r.contains("Apple Events"))
    }

    func testReport_denied_reusesAutomationHelpSingleSource() {
        // Denied must carry the FULL #288 guidance — same single text source,
        // never a paraphrase that could drift.
        let r = AutomationStatus.report(for: .denied)
        XCTAssertTrue(r.contains("-1743"))
        XCTAssertTrue(r.contains(AutomationHelp.guidance),
                      "denied remediation must be AutomationHelp.guidance verbatim (single source)")
    }

    func testReport_notDetermined_pointsAtPromptTrigger() {
        let r = AutomationStatus.report(for: .notDetermined)
        XCTAssertTrue(r.contains("NOT DETERMINED"))
        XCTAssertTrue(r.contains("prompt"), "must explain how to trigger the authorization prompt")
        XCTAssertTrue(r.contains("#288"), "must carry the binary-owns-the-grant attribution note")
    }

    func testReport_targetNotRunning_noSideEffectDisclosure() {
        let r = AutomationStatus.report(for: .targetNotRunning)
        XCTAssertTrue(r.contains("not running"))
        XCTAssertTrue(r.contains("side effects"),
                      "must disclose the probe deliberately does not launch Mail")
    }

    func testReport_unknown_surfacesCodeAndStaysConservative() {
        let r = AutomationStatus.report(for: .unknown(-9999))
        XCTAssertTrue(r.contains("-9999"), "unexpected status codes must surface verbatim")
        XCTAssertTrue(r.contains(AutomationHelp.guidance),
                      "unknown is judged conservatively — remediation included")
    }

    func testCheckAutomationTool_registeredWithHonestDescription() {
        let tool = CheAppleMailMCPServer.defineTools().first { $0.name == "check_automation" }
        XCTAssertNotNil(tool, "check_automation must be registered (#293)")
        let desc = tool?.description ?? ""
        XCTAssertTrue(desc.contains("Non-prompting"), "must advertise the no-side-effect probe contract")
        XCTAssertTrue(desc.contains("OWN grant"), "must carry the #288 attribution warning")
        XCTAssertTrue(desc.contains("open_mailto"), "must point at the zero-TCC fallback (#287)")
    }
}
