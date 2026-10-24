import XCTest
@testable import CheAppleMailMCP

/// #522 — after a Mail operation times out, its outcome is unknown. These tests
/// pin two things: the messages tell the caller which read-only queries can
/// produce evidence (and what a missing row does NOT prove), and none of that
/// loosens the send gate #415/#301 established (UNKNOWN, NOT retrying, and the
/// `isTimeoutError` / `isPostDispatchError` classification).
///
/// Everything here is a pure function or a MailController test seam; no test
/// composes, sends, or creates a draft.
final class TimeoutOutcomeHintTests: XCTestCase {

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    private static let executions: [ScriptTimeoutExecution] = [
        .inProcess, .subprocess(exitConfirmed: true), .subprocess(exitConfirmed: false),
    ]

    private func timeout(_ execution: ScriptTimeoutExecution) -> MailError {
        .scriptTimedOut(seconds: 90, automationGranted: true, execution: execution)
    }

    private func message(_ error: MailError, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case MailError.scriptFailed(let message, let code) = error else {
            XCTFail("expected scriptFailed, got \(error)", file: file, line: line)
            return ""
        }
        XCTAssertEqual(code, -1, "the unknown-state errors keep code -1", file: file, line: line)
        return message
    }

    private static let denials = ["NOT evidence", "does not prove", "not a confirmation"]

    // MARK: - T1 hint text

    func testHint_eachKind_namesSearchEmailsSubjectQuery_andDeniesNegativeEvidence() {
        for kind in TimeoutOutcomeKind.allCases {
            let hint = timeoutVerificationHint(kind)
            XCTAssertFalse(hint.isEmpty, "\(kind) has no hint")
            XCTAssertTrue(hint.contains("search_emails"), "\(kind): \(hint)")
            XCTAssertTrue(hint.contains("field=\"subject\""), "\(kind): \(hint)")
            XCTAssertTrue(Self.denials.contains { hint.contains($0) },
                          "\(kind) must say what a missing row does not show: \(hint)")
        }
        XCTAssertTrue(timeoutVerificationHint(.draftSave).contains("list_drafts"))
        XCTAssertTrue(timeoutVerificationHint(.draftDelete).contains("list_drafts"))
    }

    func testHint_sendFlow_pointsAtFullDiskAccessAndForbidsAutomaticResend() {
        let hint = timeoutVerificationHint(.sendFlow)
        XCTAssertTrue(hint.contains("Full Disk Access"), hint)
        XCTAssertTrue(hint.contains("date_received"), hint)
        XCTAssertTrue(hint.contains("Do not resend automatically"), hint)
        XCTAssertFalse(hint.contains("date_from"),
                       "date_from filters on date_received, whose reliability for drafts and Sent copies is unmeasured")
    }

    // MARK: - T7 no verdict vocabulary

    func testHints_useNoVerdictVocabulary() {
        let banned = ["safe to retry", "safe to resend", "safe to re-send", "confirmed sent",
                      "was not sent", "not sent", "has been sent", "definitely"]
        for kind in TimeoutOutcomeKind.allCases {
            let hint = timeoutVerificationHint(kind)
            XCTAssertFalse(hint.isEmpty, "\(kind) has no hint")
            for phrase in banned {
                XCTAssertFalse(hint.localizedCaseInsensitiveContains(phrase),
                               "\(kind) must not read as a verdict (\"\(phrase)\"): \(hint)")
            }
        }
    }

    func testHints_doNotEchoOrNameAnyCallerContent() {
        // D4: the hint is a pure function of the kind; it never receives the
        // subject, so it cannot echo it.
        for kind in TimeoutOutcomeKind.allCases {
            XCTAssertEqual(timeoutVerificationHint(kind), timeoutVerificationHint(kind))
            XCTAssertFalse(timeoutVerificationHint(kind).contains("example.invalid"))
        }
    }

    // MARK: - T2 / T3 compose send state

    func testUnknownSendStateError_timeout_keepsGate_andCarriesHintBeforeEcho() {
        let hint = timeoutVerificationHint(.sendFlow)
        for execution in Self.executions {
            let error = timeout(execution)
            XCTAssertTrue(isTimeoutError(error))
            let result = unknownSendStateError(error)
            let text = message(result)
            XCTAssertTrue(text.contains("UNKNOWN"), text)
            XCTAssertTrue(text.contains("NOT retrying"), text)
            XCTAssertTrue(text.contains("may or may not"), text)
            XCTAssertTrue(text.contains("search_emails"), text)
            let hintRange = text.range(of: hint)
            let echoRange = text.range(of: "Original error: ")
            XCTAssertNotNil(hintRange, "the whole hint must be present: \(text)")
            XCTAssertNotNil(echoRange, text)
            if let hintRange, let echoRange {
                XCTAssertLessThan(hintRange.upperBound, echoRange.lowerBound,
                                  "the hint must come BEFORE the clamped echo, or the 200-char clamp can cut it")
            }
            // Classification of the produced error is unchanged.
            XCTAssertFalse(isTimeoutError(result))
            XCTAssertFalse(isPostDispatchError(result))
        }
    }

    func testUnknownSendStateError_timeout_echoStaysClamped_andHintStaysWhole() {
        // The subprocess description alone is far longer than the 200-char echo cap.
        let error = timeout(.subprocess(exitConfirmed: false))
        XCTAssertGreaterThan((error.errorDescription ?? "").count, 200)
        let text = message(unknownSendStateError(error))
        XCTAssertTrue(text.contains(timeoutVerificationHint(.sendFlow)), text)
        let echo = text.components(separatedBy: "Original error: ").last ?? ""
        XCTAssertLessThanOrEqual(echo.count, 200, "echo must stay clamped")
        XCTAssertFalse(echo.isEmpty)
    }

    func testUnknownSendStateError_postDispatch_carriesHint_andHugeEchoDoesNotCutIt() {
        let huge = MailError.scriptFailed(
            message: "POSTDISPATCH: " + String(repeating: "x", count: 5000), code: -1)
        XCTAssertTrue(isPostDispatchError(huge))
        let result = unknownSendStateError(huge)
        let text = message(result)
        XCTAssertTrue(text.contains("UNKNOWN"), text)
        XCTAssertTrue(text.contains("NOT retrying"), text)
        XCTAssertTrue(text.contains("already dispatched"), text)
        let hint = timeoutVerificationHint(.sendFlow)
        XCTAssertTrue(text.contains(hint), text)
        if let hintRange = text.range(of: hint), let echoRange = text.range(of: "Original error: ") {
            XCTAssertLessThan(hintRange.upperBound, echoRange.lowerBound,
                              "the hint must come BEFORE the clamped echo")
        } else {
            XCTFail("hint or echo marker missing: \(text)")
        }
        let echo = text.components(separatedBy: "Original error: ").last ?? ""
        XCTAssertLessThanOrEqual(echo.count, 200)
        // The reply is a new scriptFailed whose text does not start with the sentinel,
        // so it can never be re-read as a post-dispatch error nor as a timeout.
        XCTAssertFalse(isPostDispatchError(result))
        XCTAssertFalse(isTimeoutError(result))
    }

    // MARK: - T6 draft delete timeout

    func testDraftDeleteTimeout_carriesHint_withoutGuiOrReadOnlyWords() async {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in Thread.sleep(forTimeInterval: 0.5); return "late" },
            refusal: nil, scriptTimeout: 0.05)
        do {
            _ = try await MailController.shared.runDraftDeleteScript("noop", timeout: 0.05)
            XCTFail("expected timeout")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("deletion outcome is unknown"), text)
            XCTAssertTrue(text.contains("Check the drafts mailbox before retrying"), text)
            XCTAssertTrue(text.contains(timeoutVerificationHint(.draftDelete)), text)
            XCTAssertTrue(text.contains("list_drafts"), text)
            XCTAssertTrue(text.contains("search_emails"), text)
            XCTAssertFalse(text.contains("GUI"), text)
            XCTAssertFalse(text.contains("read-only"), text)
        }
    }

    // MARK: - T8 documentation

    private static func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testReadme_hasTimeoutSection_namingTheTools() throws {
        let readme = try Self.repoFile("README.md")
        let heading = "### After a timeout: what can and cannot be known"
        let start = try XCTUnwrap(readme.range(of: heading), "README must keep the #522 section")
        let rest = readme[start.upperBound...]
        let end = rest.range(of: "\n---\n")?.lowerBound ?? rest.endIndex
        let section = String(rest[..<end])
        for needle in ["search_emails", "list_drafts", "UNKNOWN", "field=\"subject\"", "date_received"] {
            XCTAssertTrue(section.contains(needle), "README timeout section must mention \(needle)")
        }
        XCTAssertTrue(readme.contains("(#after-a-timeout-what-can-and-cannot-be-known)"),
                      "the Troubleshooting row must link to the section")
        XCTAssertFalse(section.localizedCaseInsensitiveContains("safe to retry"))
    }

    func testRepoRule_keepsTheBoundaryAndTheMeasurementProtocol() throws {
        let rule = try Self.repoFile(".claude/rules/timeout-outcome-boundary.md")
        for needle in ["S1", "S2", "S3", "UNKNOWN", "NOT retrying", "isTimeoutError", "isPostDispatchError"] {
            XCTAssertTrue(rule.contains(needle), "the rule file must keep \(needle)")
        }
    }
}
