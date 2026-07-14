import XCTest
@testable import CheAppleMailMCP

/// #254 — production-site behavioral tests through the MailController test
/// seams (script-runner + ineligibility overrides). Closes the #241 wiring
/// guard's blind spot: that guard pins call-site PRESENCE only, so a single
/// site swapping its disclosure/warn family (compose ↔ reply) stayed green.
/// These tests drive the REAL composeEmail/createDraft/replyEmail/forwardEmail
/// and assert the family-correct result suffix — no live Mail involved.
final class MailControllerSeamTests: XCTestCase {

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil)
        try await super.tearDown()
    }

    /// Marker unique to the COMPOSE-family disclosure (`legacyPathDisclosure`).
    private let composeFamilyMarker = "plain format + non-empty subject + default sender"
    /// Marker unique to the REPLY-family disclosure (`legacyReplyPathDisclosure`).
    private let replyFamilyMarker = "the quoted original's cite block is normal"

    func testComposeEmail_ineligible_legacyResultCarriesComposeFamilySuffix() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                XCTAssertTrue(script.contains("make new outgoing message"),
                              "legacy compose must run the outgoing-message script")
                return "Email sent successfully"
            },
            ineligibility: { "seam-test reason" })
        let result = try await MailController.shared.composeEmail(
            to: ["a@b.c"], subject: "s", body: "b")
        XCTAssertTrue(result.hasPrefix("Email sent successfully"))
        XCTAssertTrue(result.contains("Reason: seam-test reason."))
        XCTAssertTrue(result.contains(composeFamilyMarker),
                      "compose_email must use the COMPOSE-family disclosure: \(result)")
        XCTAssertFalse(result.contains(replyFamilyMarker))
    }

    func testCreateDraft_ineligible_legacyResultCarriesComposeFamilySuffix() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" },
            ineligibility: { "seam-test reason" })
        let result = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b")
        XCTAssertTrue(result.hasPrefix("Draft created successfully"))
        XCTAssertTrue(result.contains(composeFamilyMarker), result)
        XCTAssertFalse(result.contains(replyFamilyMarker))
    }

    func testReplyEmail_ineligible_legacyResultCarriesReplyFamilySuffix() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Reply sent successfully" },
            ineligibility: { "seam-test reason" })
        let result = try await MailController.shared.replyEmail(
            id: "123", mailbox: "INBOX", accountName: "a@b.c", body: "new text")
        XCTAssertTrue(result.hasPrefix("Reply sent successfully"))
        XCTAssertTrue(result.contains(replyFamilyMarker),
                      "reply_email must use the REPLY-family disclosure: \(result)")
        XCTAssertFalse(result.contains(composeFamilyMarker))
    }

    func testForwardEmail_withBody_ineligible_carriesReplyFamilySuffix() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email forwarded successfully" },
            ineligibility: { "seam-test reason" })
        let result = try await MailController.shared.forwardEmail(
            id: "123", mailbox: "INBOX", accountName: "a@b.c", to: ["x@y.z"], body: "note")
        XCTAssertTrue(result.hasPrefix("Email forwarded successfully"))
        XCTAssertTrue(result.contains(replyFamilyMarker), result)
        XCTAssertFalse(result.contains(composeFamilyMarker))
    }

    func testForwardEmail_bodyless_neverSuffixed_neverProbesEligibility() async throws {
        // #229 invariant, now pinned at the PRODUCTION site: a bodyless forward
        // injects nothing → already wrapper-free → no disclosure suffix, and
        // the eligibility probe must not even run.
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email forwarded successfully" },
            ineligibility: { XCTFail("bodyless forward must not probe eligibility"); return "x" })
        let result = try await MailController.shared.forwardEmail(
            id: "123", mailbox: "INBOX", accountName: "a@b.c", to: ["x@y.z"], body: nil)
        XCTAssertEqual(result, "Email forwarded successfully",
                       "bodyless forward result must carry NO suffix")
    }

    func testEligible_cleanPathFails_falseFromRunner_fallsBackWithClampedEcho() async throws {
        // Tried-and-failed branch at the production site: eligible → clean path
        // (mailto script) throws via the runner → legacy runs → clamped echo.
        enum Boom: Error, LocalizedError { case gui
            var errorDescription: String? { "window vanished\nmid-flight" } }
        var calls = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                calls += 1
                if script.contains("mailto ") { throw Boom.gui }
                return "Email sent successfully"
            },
            ineligibility: { nil })
        let result = try await MailController.shared.composeEmail(
            to: ["a@b.c"], subject: "s", body: "b")
        XCTAssertGreaterThanOrEqual(calls, 2, "clean attempt + legacy run")
        XCTAssertTrue(result.contains("Reason: mailto GUI path failed: window vanished mid-flight"),
                      "clamped (newline-folded) echo must reach the suffix: \(result)")
    }
}
