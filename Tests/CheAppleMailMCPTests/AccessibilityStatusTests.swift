import XCTest
@testable import CheAppleMailMCP

final class AccessibilityStatusTests: XCTestCase {
    func testDeniedSummaryProvidesAnAvailableAlternative() {
        let text = AccessibilityStatus.summary(.denied)
        XCTAssertTrue(text.contains("DENIED"))
        XCTAssertTrue(text.contains("refused"), text)
        XCTAssertTrue(text.contains("open_mailto"), text)
        XCTAssertFalse(text.contains("falls back"), text)
    }

    func testGuidanceDoesNotPromiseComposeWithoutAccessibility() {
        let text = AccessibilityStatus.guidance()
        XCTAssertFalse(text.contains("still work"), text)
        XCTAssertFalse(text.contains("legacy"), text)
        XCTAssertTrue(text.contains("open_mailto"), text)
        XCTAssertTrue(text.contains("no attachments"), text)
        XCTAssertTrue(text.contains("save or send"), text)
    }
    func testGrantedReportSeparatesPreflightRefusalFromRuntimeFailure() {
        let text = AccessibilityStatus.report(for: .granted)
        for required in ["GRANTED", "Six named preflight", "non-plain", "subject", "Accessibility",
                         "from_address", "non-ASCII", "display-name", "over-long mailto URL", "before composition starts",
                         "may leave", "send state unknown", "Sent/Outbox", "Automation",
                         "open_mailto", "no attachments", "save or send"] {
            XCTAssertTrue(text.contains(required), required + ": " + text)
        }
        XCTAssertFalse(text.contains("falls back"), text)
        XCTAssertFalse(text.contains("env hatch"), text)
    }

    func testDeniedAndUnsupportedReportsPreserveTheirStatus() {
        let denied = AccessibilityStatus.report(for: .denied)
        for required in ["DENIED", "refused", "open_mailto", "no attachments",
                         "save or send", "System Settings"] {
            XCTAssertTrue(denied.contains(required), required + ": " + denied)
        }
        XCTAssertFalse(denied.contains("GRANTED"))
        XCTAssertFalse(denied.contains("still work"))
        let unsupported = AccessibilityStatus.report(for: .unsupported)
        XCTAssertTrue(unsupported.contains("UNSUPPORTED"))
        XCTAssertTrue(unsupported.contains("not a macOS"))
        XCTAssertFalse(unsupported.contains("GRANTED"))
    }

    func testRegisteredAccessibilityAndMailtoDescriptionsAreCurrent() throws {
        let tools = CheAppleMailMCPServer.defineTools()
        let check = try XCTUnwrap(tools.first { $0.name == "check_accessibility" })
        let mailto = try XCTUnwrap(tools.first { $0.name == "open_mailto" })
        let checkText = try XCTUnwrap(check.description)
        let mailtoText = try XCTUnwrap(mailto.description)
        XCTAssertTrue(checkText.contains("refused before composition starts"))
        XCTAssertTrue(checkText.contains("open_mailto"))
        XCTAssertTrue(checkText.contains("does not check Automation"))
        XCTAssertFalse(checkText.contains("compose still works"))
        XCTAssertFalse(mailtoText.contains("legacy AppleScript injection"))
        XCTAssertTrue(mailtoText.contains("no attachments"))
        XCTAssertTrue(mailtoText.contains("Save or send manually"))
    }

    func testUnknownSendErrorsDoNotAdvertiseRemovedRetryPath() {
        let errors: [Error] = [
            MailError.scriptTimedOut(seconds: 45, automationGranted: true),
            MailError.scriptFailed(message: "POSTDISPATCH: test", code: -1),
        ]
        for error in errors {
            guard case MailError.scriptFailed(let message, _) = unknownSendStateError(error) else {
                return XCTFail("expected send-state error")
            }
            XCTAssertTrue(message.contains("UNKNOWN"))
            XCTAssertTrue(message.contains("NOT retrying"))
            XCTAssertTrue(message.contains("Outbox"))
            XCTAssertFalse(message.contains("legacy"))
        }
    }

}
