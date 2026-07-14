import XCTest
@testable import CheAppleMailMCP

/// #239 — `require_wrapper_free: true` turns the silent wrapped-body fallback
/// into a clean failure: an ineligible call errors out with the named reason
/// and actionable alternatives instead of producing a wrapped draft the user
/// then has to clean up. Default false keeps graceful fallback byte-identical.
final class RequireWrapperFreeTests: XCTestCase {

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil)
        try await super.tearDown()
    }

    // MARK: refusal message (pure)

    func testRefusalMessage_namesReasonAndAlternatives() {
        let msg = requireWrapperFreeRefusal(reason: "custom from_address (see #219)")
        XCTAssertTrue(msg.contains("custom from_address (see #219)"),
                      "refusal must carry the named ineligibility reason: \(msg)")
        XCTAssertTrue(msg.contains("require_wrapper_free"), msg)
        // the four actionable alternatives
        XCTAssertTrue(msg.contains("from_address"), "must suggest omitting the custom sender")
        XCTAssertTrue(msg.contains("plain"), "must suggest the plain format")
        XCTAssertTrue(msg.contains("Accessibility"), "must point at the Accessibility grant")
        XCTAssertTrue(msg.contains("CHE_MAIL_DISABLE_MAILTO_COMPOSE"), "must name the env hatch")
        XCTAssertFalse(msg.contains("\n"), "single-line error message")
    }

    // MARK: production sites via the #254 seams

    func testStrictIneligible_throwsNamedReason_neverRunsAnyScript() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("no script may run — no draft, no send"); return "" },
            ineligibility: { "strict-test reason" })
        do {
            _ = try await MailController.shared.composeEmail(
                to: ["a@b.c"], subject: "s", body: "b", requireWrapperFree: true)
            XCTFail("strict + ineligible must throw")
        } catch {
            XCTAssertTrue("\(error)".contains("strict-test reason"),
                          "error must carry the named reason: \(error)")
        }
    }

    func testStrictEligible_cleanPathFailure_propagatesWithoutFallback() async throws {
        enum Boom: Error, LocalizedError { case gui
            var errorDescription: String? { "GUI step failed" } }
        var calls = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in calls += 1; throw Boom.gui },
            ineligibility: { nil })
        do {
            _ = try await MailController.shared.composeEmail(
                to: ["a@b.c"], subject: "s", body: "b", requireWrapperFree: true)
            XCTFail("strict clean-path failure must propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("GUI step failed"),
                          error.localizedDescription)
        }
        XCTAssertEqual(calls, 1, "exactly the clean attempt — legacy must NOT run")
    }

    func testStrictEligible_cleanPathSucceeds_normalResult() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully (mailto path)" },
            ineligibility: { nil })
        let result = try await MailController.shared.composeEmail(
            to: ["a@b.c"], subject: "s", body: "b", requireWrapperFree: true)
        XCTAssertEqual(result, "Email sent successfully (mailto path)")
    }

    func testDefaultFalse_gracefulFallbackUnchanged() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" },
            ineligibility: { "some reason" })
        let result = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b")
        XCTAssertTrue(result.hasPrefix("Draft created successfully"))
        XCTAssertTrue(result.contains("[legacy path"),
                      "default behavior must keep the graceful fallback + disclosure")
    }

    func testCreateDraft_strictIneligible_throwsToo() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("no script may run"); return "" },
            ineligibility: { "strict-test reason" })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.createDraft(
                to: ["a@b.c"], subject: "s", body: "b", requireWrapperFree: true))
    }

    // MARK: schema surface

    func testSchema_bothToolsAdvertiseTheParameter() throws {
        for name in ["compose_email", "create_draft"] {
            let tool = CheAppleMailMCPServer.defineTools().first { $0.name == name }
            let t = try XCTUnwrap(tool)
            guard case .object(let schema) = t.inputSchema,
                  case .object(let props)? = schema["properties"] else {
                return XCTFail("\(name) inputSchema must have properties")
            }
            XCTAssertNotNil(props["require_wrapper_free"],
                            "\(name) must advertise require_wrapper_free (#239)")
        }
    }
}

/// Async variant of XCTAssertThrowsError (XCTest lacks one).
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
