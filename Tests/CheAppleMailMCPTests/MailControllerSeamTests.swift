import XCTest
@testable import CheAppleMailMCP

/// #254/#304 — production-site behavioral tests through the MailController test
/// seams (script-runner + refusal overrides). Closes the wiring guard's blind
/// spot: that guard pins call-site PRESENCE only, so a single site wired to the
/// wrong helper stayed green. These tests drive the REAL
/// composeEmail/createDraft/replyEmail/forwardEmail — no live Mail involved.
///
/// Before #304 these tests asserted which DISCLOSURE SUFFIX each site appended
/// after silently falling back to the body-assigning path. There is no fallback
/// and no suffix now, so what they pin instead is the property that replaced it:
/// each site REFUSES, runs nothing, and returns the clean result verbatim when
/// it does proceed.
final class MailControllerSeamTests: XCTestCase {

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    func testComposeEmail_refused_runsNothing() async throws {
        var scripts = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in scripts += 1; return "Email sent successfully" },
            refusal: { .accessibilityNotGranted })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["a@b.c"], subject: "s", body: "b"))
        XCTAssertEqual(scripts, 0, "a refused send must run no script at all")
    }

    func testCreateDraft_refused_runsNothing() async throws {
        var scripts = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in scripts += 1; return "Draft created successfully" },
            refusal: { .accessibilityNotGranted })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.createDraft(
                to: ["a@b.c"], subject: "s", body: "b"))
        XCTAssertEqual(scripts, 0)
    }

    func testReplyEmail_refused_runsNothing() async throws {
        var scripts = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in scripts += 1; return "Reply sent successfully" },
            refusal: { .accessibilityNotGranted })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.replyEmail(
                id: "123", mailbox: "INBOX", accountName: "a@b.c", body: "new text"))
        XCTAssertEqual(scripts, 0, "a refused reply must not even open the window")
    }

    func testForwardEmail_withBody_refused_runsNothing() async throws {
        var scripts = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in scripts += 1; return "Email forwarded successfully" },
            refusal: { .accessibilityNotGranted })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.forwardEmail(
                id: "123", mailbox: "INBOX", accountName: "a@b.c", to: ["x@y.z"], body: "note"))
        XCTAssertEqual(scripts, 0)
    }

    func testForwardEmail_bodyless_runsDirectly_neverProbesRefusal() async throws {
        // #229 invariant, now pinned at the PRODUCTION site: a bodyless forward
        // assigns nothing → already wrapper-free → runs directly, and the
        // pre-flight refusal probe must not even run (#304: it needs no
        // Accessibility grant, so it must not be refused for lacking one).
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email forwarded successfully" },
            refusal: { XCTFail("bodyless forward must not probe for a refusal")
                       return .accessibilityNotGranted })
        let result = try await MailController.shared.forwardEmail(
            id: "123", mailbox: "INBOX", accountName: "a@b.c", to: ["x@y.z"], body: nil)
        XCTAssertEqual(result, "Email forwarded successfully")
    }

    func testEligible_cleanPathFails_propagates_withoutASecondScript() async throws {
        // What used to be the tried-and-failed FALLBACK branch. The clean path
        // is the only path now, so a GUI failure must surface — and crucially
        // must not be followed by a second script (that second run was the
        // body-assigning one).
        enum Boom: Error, LocalizedError { case gui
            var errorDescription: String? { "window vanished mid-flight" } }
        var calls = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in calls += 1; throw Boom.gui },
            refusal: { nil })
        do {
            _ = try await MailController.shared.composeEmail(
                to: ["a@b.c"], subject: "s", body: "b")
            XCTFail("the GUI failure must propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("window vanished"),
                          error.localizedDescription)
        }
        XCTAssertEqual(calls, 1, "exactly one attempt — nothing retries it")
    }

    func testEligible_cleanPathSucceeds_resultHasNoSuffix() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" },
            refusal: { nil })
        let result = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b")
        XCTAssertEqual(result, "Draft created successfully",
                       "no path disclosure — there is only one path")
    }
}
