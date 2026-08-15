import XCTest
@testable import CheAppleMailMCP

/// #304 — a composing call that cannot use its non-injecting path FAILS, with a
/// named reason and an executable alternative, and leaves nothing behind.
///
/// This file replaces `RequireWrapperFreeTests`. That behavior used to be opt-in
/// through `require_wrapper_free: true`; the default was a silent fallback to a
/// builder that assigned the body via AppleScript, which Mail wraps in
/// `<blockquote type="cite">`. The flag is gone because the fallback is gone —
/// what it bought is now the only behavior there is.
final class ComposeRefusalTests: XCTestCase {

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    // MARK: the closed six — each names its reason AND an executable alternative

    /// The enumeration is closed on purpose (`common-spec-prose-enumeration`):
    /// a seventh case must not be added by analogy, because every case here is
    /// decidable BEFORE any side effect and therefore carries the "nothing
    /// happened" guarantee. Mid-operation failures are a different contract
    /// (see `testRuntimeFailure_propagates_neverRetried`).
    private let allRefusals: [ComposeRefusal] = [
        .richTextFormat(.markdown),
        .emptySubject,
        .accessibilityNotGranted,
        .customSenderNotSimple,
        .nonASCIIAttachmentPath,
        .displayNameRecipient,
    ]

    func testEveryRefusal_namesAReasonAndAnAlternative() {
        for refusal in allRefusals {
            let msg = refusal.message
            XCTAssertFalse(msg.isEmpty, "\(refusal) must carry a message")
            XCTAssertFalse(msg.contains("\n"), "single-line error message: \(msg)")
            // "what to do instead" — every message must offer at least one of
            // these verbs. A refusal with no recipe is worse than the silent
            // degradation it replaced.
            let hasRecipe = ["Use ", "use ", "Supply", "Pass ", "Grant ", "Create the draft"]
                .contains { msg.contains($0) }
            XCTAssertTrue(hasRecipe, "\(refusal) must state an alternative: \(msg)")
        }
    }

    func testRichTextFormat_namesRemovalAndReplacement() {
        for format in [BodyFormat.markdown, .html] {
            let msg = ComposeRefusal.richTextFormat(format).message
            XCTAssertTrue(msg.contains(format.rawValue), msg)
            XCTAssertTrue(msg.contains("no longer supported"), msg)
            XCTAssertTrue(msg.contains("'plain'"), "must direct the caller to plain: \(msg)")
            XCTAssertTrue(msg.contains("#308") && msg.contains("#309"),
                          "must point at the rich-text follow-ups: \(msg)")
        }
    }

    func testAccessibility_namesTheZeroTCCAlternative() {
        let msg = ComposeRefusal.accessibilityNotGranted.message
        XCTAssertTrue(msg.contains("Accessibility"), msg)
        XCTAssertTrue(msg.contains("open_mailto"), "must name the zero-TCC path: \(msg)")
        XCTAssertTrue(msg.contains("cannot carry attachments"),
                      "must state open_mailto's limit rather than let the caller discover it: \(msg)")
    }

    func testNonASCIIAttachment_givesTheManualDragRecipe() {
        let msg = ComposeRefusal.nonASCIIAttachmentPath.message
        XCTAssertTrue(msg.contains("#220"), msg)
        XCTAssertTrue(msg.contains("drag"), "must give the manual recipe: \(msg)")
        XCTAssertTrue(msg.contains("do not rename"),
                      "renaming to ASCII changes what the recipient sees — must be ruled out: \(msg)")
    }

    // MARK: selection order

    func testRefusalOrder_followsTheEnumeration() {
        // A call that trips several conditions reports the first, so a caller
        // fixing them one at a time converges.
        XCTAssertEqual(
            composeRefusal(format: .markdown, accessibilityTrusted: false,
                           hasCustomSender: false, hasSubject: false),
            .richTextFormat(.markdown))
        XCTAssertEqual(
            composeRefusal(format: .plain, accessibilityTrusted: false,
                           hasCustomSender: false, hasSubject: false),
            .emptySubject)
        XCTAssertEqual(
            composeRefusal(format: .plain, accessibilityTrusted: false,
                           hasCustomSender: false, hasSubject: true),
            .accessibilityNotGranted)
        XCTAssertEqual(
            composeRefusal(format: .plain, accessibilityTrusted: true,
                           hasCustomSender: true, hasSubject: true,
                           customSenderIsSimple: false),
            .customSenderNotSimple)
        XCTAssertEqual(
            composeRefusal(format: .plain, accessibilityTrusted: true,
                           hasCustomSender: false, hasSubject: true,
                           attachmentsGuiSafe: false),
            .nonASCIIAttachmentPath)
        XCTAssertEqual(
            composeRefusal(format: .plain, accessibilityTrusted: true,
                           hasCustomSender: false, hasSubject: true,
                           recipientsAddrSpecOnly: false),
            .displayNameRecipient)
        XCTAssertNil(
            composeRefusal(format: .plain, accessibilityTrusted: true,
                           hasCustomSender: false, hasSubject: true))
    }

    func testReplyForwardRefusal_onlyTwoConditionsApply() {
        XCTAssertEqual(replyForwardRefusal(format: .html, accessibilityTrusted: true),
                       .richTextFormat(.html))
        XCTAssertEqual(replyForwardRefusal(format: .plain, accessibilityTrusted: false),
                       .accessibilityNotGranted)
        XCTAssertNil(replyForwardRefusal(format: .plain, accessibilityTrusted: true))
    }

    // MARK: zero side effects at the production sites

    func testComposeRefused_throwsNamedReason_neverRunsAnyScript() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("no script may run — no draft, no send"); return "" },
            refusal: { .accessibilityNotGranted })
        do {
            _ = try await MailController.shared.composeEmail(
                to: ["a@b.c"], subject: "s", body: "b")
            XCTFail("a refused compose must throw")
        } catch {
            XCTAssertTrue("\(error)".contains("Accessibility"),
                          "error must carry the named reason: \(error)")
            XCTAssertTrue("\(error)".contains("open_mailto"),
                          "error must carry the alternative: \(error)")
        }
    }

    func testCreateDraftRefused_throws_andCreatesNothing() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("no script may run"); return "" },
            refusal: { .nonASCIIAttachmentPath })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.createDraft(
                to: ["a@b.c"], subject: "s", body: "b"))
    }

    func testUpdateDraftRefused_deletesNothing() async throws {
        // #276's upsert is create-then-delete. A refusal must land BEFORE the
        // create, so the existing draft is never the casualty of a rejected
        // replacement.
        // The locate step is a READ and may run; what must not happen is the
        // create or the delete.
        var mutations: [String] = []
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                if script.contains("delete") || script.contains("outgoing message") {
                    mutations.append(String(script.prefix(60)))
                }
                return "101\u{1F}old subject"
            },
            refusal: { .accessibilityNotGranted })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.updateDraft(
                draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
                to: ["a@b.c"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, fromAddress: nil))
        XCTAssertTrue(mutations.isEmpty,
                      "a refused replacement must neither create nor delete: \(mutations)")
    }

    func testReplyRefused_throws_neverRunsAnyScript() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("no script may run — nothing sent, nothing saved"); return "" },
            refusal: { .accessibilityNotGranted })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.replyEmail(
                id: "1", mailbox: "INBOX", accountName: "a@b.c", body: "b"))
    }

    func testForwardWithBodyRefused_throws_neverRunsAnyScript() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("no script may run"); return "" },
            refusal: { .accessibilityNotGranted })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.forwardEmail(
                id: "1", mailbox: "INBOX", accountName: "a@b.c", to: ["x@y.z"], body: "note"))
    }

    // MARK: the clean path still works, and runtime failures are NOT refusals

    func testEligible_cleanPathSucceeds_resultIsVerbatim() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully (mailto path)" },
            refusal: { nil })
        let result = try await MailController.shared.composeEmail(
            to: ["a@b.c"], subject: "s", body: "b")
        XCTAssertEqual(result, "Email sent successfully (mailto path)",
                       "no disclosure suffix — there is no other path to disclose")
    }

    func testRuntimeFailure_propagates_neverRetried() async throws {
        enum Boom: Error, LocalizedError { case gui
            var errorDescription: String? { "GUI step failed" } }
        var calls = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in calls += 1; throw Boom.gui },
            refusal: { nil })
        do {
            _ = try await MailController.shared.composeEmail(
                to: ["a@b.c"], subject: "s", body: "b")
            XCTFail("a mid-operation failure must propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("GUI step failed"),
                          error.localizedDescription)
        }
        XCTAssertEqual(calls, 1, "exactly the clean attempt — nothing may retry it")
    }

    func testPostDispatchFailure_mapsToUnknownSendState() async throws {
        // #242: once the send keystroke has been dispatched the state is
        // UNKNOWN. A raw POSTDISPATCH token invites an auto-retrying caller to
        // re-send, so the message must say what to check instead.
        var calls = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in
                calls += 1
                throw MailError.scriptFailed(message: "POSTDISPATCH: window gone", code: -1)
            },
            refusal: { nil })
        do {
            _ = try await MailController.shared.composeEmail(
                to: ["a@b.c"], subject: "s", body: "b")
            XCTFail("must throw")
        } catch {
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("Sent"), "must direct to Sent/Outbox: \(msg)")
            XCTAssertFalse(msg.lowercased().contains("nothing was sent"),
                           "a post-dispatch failure must NOT claim it was a no-op: \(msg)")
        }
        XCTAssertEqual(calls, 1)
    }

    // MARK: schema surface

    func testSchema_composingToolsDropTheRemovedParameters() throws {
        for name in ["compose_email", "create_draft", "reply_email", "forward_email", "update_draft"] {
            let tool = CheAppleMailMCPServer.defineTools().first { $0.name == name }
            let t = try XCTUnwrap(tool, "\(name) must exist")
            guard case .object(let schema) = t.inputSchema,
                  case .object(let props)? = schema["properties"] else {
                return XCTFail("\(name) inputSchema must have properties")
            }
            XCTAssertNil(props["require_wrapper_free"],
                         "\(name) must NOT advertise require_wrapper_free (#304)")
            XCTAssertNil(props["sanitize_links"],
                         "\(name) must NOT advertise sanitize_links (#304)")
        }
    }

    func testSchema_formatEnumIsPlainOnly() throws {
        for name in ["compose_email", "create_draft", "reply_email", "forward_email", "update_draft"] {
            let tool = CheAppleMailMCPServer.defineTools().first { $0.name == name }
            let t = try XCTUnwrap(tool, "\(name) must exist")
            guard case .object(let schema) = t.inputSchema,
                  case .object(let props)? = schema["properties"],
                  case .object(let format)? = props["format"],
                  case .array(let values)? = format["enum"] else {
                return XCTFail("\(name) must expose format with an enum")
            }
            XCTAssertEqual(values.compactMap { $0.stringValue }, ["plain"],
                           "\(name) format enum must be plain-only (#304)")
        }
    }

    // MARK: the boundary rejects markdown / html by name

    /// Assert on the associated value, not on `"\(error)"` — the latter
    /// re-escapes the quotes inside the message and turns a substring check
    /// into a test of Swift's string-literal rendering.
    private func invalidParameterMessage(_ error: Error) -> String {
        guard case MailError.invalidParameter(let msg) = error else {
            XCTFail("expected MailError.invalidParameter, got \(error)")
            return ""
        }
        return msg
    }

    func testParseBodyFormat_rejectsRichTextByName() throws {
        for raw in ["markdown", "html"] {
            XCTAssertThrowsError(try parseBodyFormat(raw)) { error in
                let msg = self.invalidParameterMessage(error)
                XCTAssertTrue(msg.contains(raw), msg)
                XCTAssertTrue(msg.contains("no longer supported"),
                              "must name the removal, not report an unknown value: \(msg)")
                XCTAssertTrue(msg.contains("'plain'"), msg)
            }
        }
    }

    func testParseBodyFormat_unknownValueNamesThePermittedOne() throws {
        XCTAssertThrowsError(try parseBodyFormat("rtf")) { error in
            let msg = self.invalidParameterMessage(error)
            XCTAssertTrue(msg.contains("\"plain\""), msg)
            XCTAssertTrue(msg.contains("rtf"), "must echo the offending value: \(msg)")
        }
    }

    func testParseBodyFormat_plainAndOmittedStillWork() throws {
        XCTAssertEqual(try parseBodyFormat("plain"), .plain)
        XCTAssertEqual(try parseBodyFormat(nil), .plain)
        XCTAssertEqual(try parseBodyFormat(""), .plain)
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
