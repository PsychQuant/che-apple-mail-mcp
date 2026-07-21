import XCTest
@testable import CheAppleMailMCP

/// #288 — -1743 (Automation TCC denied) maps to actionable guidance at the
/// single `MailError.scriptFailed` rendering sink; all other codes stay
/// byte-identical raw passthrough.
final class AutomationTCCErrorMappingTests: XCTestCase {

    func testScriptFailed_1743_carriesAutomationGuidance() {
        let e = MailError.scriptFailed(
            message: "Not authorized to send Apple events to Mail.", code: -1743)
        let desc = e.errorDescription ?? ""
        XCTAssertTrue(desc.hasPrefix("AppleScript error (-1743): Not authorized"),
                      "raw error stays first — guidance appends, never replaces")
        XCTAssertTrue(desc.contains("Privacy & Security → Automation"),
                      "must name the exact System Settings path")
        XCTAssertTrue(desc.contains("terminal app") && desc.contains("Claude.app"),
                      "must cover BOTH installs' responsible hosts")
        XCTAssertTrue(desc.contains("independent grants"),
                      "must warn the two installs are separately granted")
        XCTAssertTrue(desc.contains("open_mailto"),
                      "must point at the zero-TCC fallback (#287)")
    }

    func testScriptFailed_otherCodes_byteIdenticalPassthrough() {
        // The mapping must be surgical: any non--1743 code renders exactly as
        // before (no guidance, no suffix).
        for (msg, code) in [("Mail got an error", -1728), ("timeout", -1712), ("x", -10000)] {
            let e = MailError.scriptFailed(message: msg, code: code)
            XCTAssertEqual(e.errorDescription, "AppleScript error (\(code)): \(msg)")
        }
    }

    func testGuidance_matchesRulesLadderIronRule() {
        // The guidance and the rules-file ladder must agree on the core claim:
        // zero-TCC fallback exists and is cite-block-free.
        XCTAssertTrue(AutomationHelp.guidance.contains("cite-block-free"))
        XCTAssertTrue(AutomationHelp.guidance.contains("LaunchServices"))
    }
}
