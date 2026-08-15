import XCTest
@testable import CheAppleMailMCP

/// #241/#304 — regression-lock for the composing-path WIRING. The pure helpers
/// (`composeRefusal`, `ComposeRefusal.message`, …) are pinned elsewhere, but the
/// control flow that calls them lives inline in a singleton actor and had zero
/// non-live coverage: deleting the wiring kept the whole suite green.
/// `dispatchComposePath` extracts that control flow behind injectable closures.
///
/// #304 replaced the two-path router (clean-or-disclosed-legacy) with this
/// single-path dispatcher. What used to be a route decision is now a refusal,
/// so the branches these tests drive are: refuse before anything runs, run and
/// return verbatim, or run and propagate.
final class ComposeDispatchTests: XCTestCase {

    private enum Boom: Error, LocalizedError {
        case gui(String)
        var errorDescription: String? {
            if case .gui(let m) = self { return m }
            return "boom"
        }
    }

    func testProceed_cleanSucceeds_resultVerbatim() throws {
        var cleanCalls = 0
        let result = try dispatchComposePath(
            refusal: nil,
            cleanPath: { cleanCalls += 1; return "Draft created successfully" })
        XCTAssertEqual(result, "Draft created successfully",
                       "there is no second path, so there is nothing to disclose")
        XCTAssertFalse(result.contains("[legacy path"))
        XCTAssertEqual(cleanCalls, 1)
    }

    func testRefused_throwsTheMessage_cleanPathNeverRuns() {
        XCTAssertThrowsError(try dispatchComposePath(
            refusal: .accessibilityNotGranted,
            cleanPath: { XCTFail("clean path must not run"); return "" })) { error in
            XCTAssertEqual("\(error)".contains("Accessibility"), true, "\(error)")
            XCTAssertTrue("\(error)".contains("open_mailto"),
                          "the refusal must reach the caller with its alternative: \(error)")
        }
    }

    func testRuntimeError_propagates_unmappedByDefault() {
        XCTAssertThrowsError(try dispatchComposePath(
            refusal: nil,
            cleanPath: { throw Boom.gui("window vanished") })) { error in
            XCTAssertTrue(error.localizedDescription.contains("window vanished"),
                          error.localizedDescription)
        }
    }

    func testRuntimeError_mapperRewritesIt() {
        XCTAssertThrowsError(try dispatchComposePath(
            refusal: nil,
            cleanPath: { throw Boom.gui("POSTDISPATCH: gone") },
            mapRuntimeError: { _ in
                MailError.scriptFailed(message: "send state UNKNOWN — check Sent/Outbox", code: -1)
            })) { error in
            XCTAssertTrue("\(error)".contains("send state UNKNOWN"), "\(error)")
        }
    }

    func testMapper_isNotConsultedOnTheRefusalBranch() {
        // A refusal happens BEFORE anything runs, so it must never be dressed
        // up as a runtime condition — that is the distinction the whole design
        // rests on (pre-flight = nothing happened; runtime = something might have).
        XCTAssertThrowsError(try dispatchComposePath(
            refusal: .emptySubject,
            cleanPath: { XCTFail("clean path must not run"); return "" },
            mapRuntimeError: { _ in
                XCTFail("the runtime mapper must not see a pre-flight refusal")
                return MailError.scriptCreationFailed
            })) { error in
            XCTAssertTrue("\(error)".contains("subject"), "\(error)")
        }
    }

    func testWiring_allFourCallSitesRouteThroughTheDispatcher() throws {
        // The actual #241 target: the WIRING must not be deletable while the
        // suite stays green. compose_email, create_draft, reply_email, and
        // forward_email-with-body. A bodyless forward is deliberately NOT here:
        // it assigns no body, so it needs no Accessibility grant and must not
        // be refused for lacking one.
        let source = try Self.mailControllerSource()
        let count = source.components(separatedBy: "try dispatchComposePath(").count - 1
        XCTAssertEqual(count, 4,
                       "expected compose/createDraft/reply/forward-with-body to route via "
                       + "dispatchComposePath; found \(count)")
        XCTAssertFalse(source.contains("routeWrapperFreeCompose"),
                       "the two-path router is gone (#304)")
        XCTAssertFalse(source.contains("legacyPath:"),
                       "no call site may still name a legacy path (#304)")
    }

    static func mailControllerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// #242 — send-stage failures must NOT blindly fall back to a legacy re-send
/// (potential duplicate outbound mail). The send keystroke dispatch is wrapped
/// in a POSTDISPATCH sentinel inside the AppleScript; the Swift layer refuses
/// fallback for sentinel-marked errors and reports unknown-send-state instead.
final class SendStageNoRefallbackTests: XCTestCase {

    // MARK: builder sentinel contract

    func testMailtoScript_sendTrue_wrapsDispatchInPostDispatchSentinel() {
        let script = buildMailtoComposeScript(
            url: "mailto:a@b.c?subject=s", subject: "s", attachments: [], send: true)
        XCTAssertTrue(script.contains("POSTDISPATCH: "),
                      "send:true script must mark post-dispatch errors with the sentinel")
        // The dispatch keystroke sits inside the sentinel try-block: the
        // keystroke appears before the sentinel's own `on error _dErr`.
        let keystroke = script.range(of: "keystroke \"d\" using {command down, shift down}")
        let sentinelHandler = script.range(of: "on error _dErr")
        guard let k = keystroke, let h = sentinelHandler else {
            return XCTFail("send keystroke and sentinel handler must both be present")
        }
        XCTAssertLessThan(k.lowerBound, h.lowerBound,
                          "send keystroke must precede its sentinel on-error handler")
    }

    func testMailtoScript_sendTrue_cleanupSkipsCloseOnPostDispatch() {
        let script = buildMailtoComposeScript(
            url: "mailto:a@b.c?subject=s", subject: "s", attachments: [], send: true)
        // Three-branch handler: sentinel-marked rethrow / flag-marked rethrow /
        // genuine pre-dispatch cleanup. The close-cleanup must sit in the ELSE
        // branch only — never reachable for a marked or flag-set error.
        XCTAssertTrue(script.contains("if _mErr starts with \"POSTDISPATCH:\" then"),
                      "on-error handler must branch on the sentinel before any cleanup")
        guard let elseBranch = script.range(of: "else if _dispatched then"),
              let cleanup = script.range(of: "close _cw saving no") else {
            return XCTFail("flag branch and cleanup must both be present")
        }
        XCTAssertLessThan(elseBranch.lowerBound, cleanup.lowerBound,
                          "cleanup (window close) must come after both rethrow branches"
                          + " — the window is the user's only evidence on unknown send state")
    }

    func testMailtoScript_sendFalse_noSentinel() {
        // create_draft (⌘S) keeps the plain fallback: a duplicated DRAFT is
        // visible and harmless, unlike a duplicated outbound send.
        let script = buildMailtoComposeScript(
            url: "mailto:a@b.c?subject=s", subject: "s", attachments: [], send: false)
        XCTAssertFalse(script.contains("POSTDISPATCH"),
                       "draft save path must not carry the send sentinel")
        XCTAssertFalse(script.contains("_dispatched"),
                       "draft save path must not carry the dispatch flag either")
    }

    func testMailtoScript_sendTrue_tailProtectedByDispatchedFlag() {
        // #242 verify REQUIRED hardening (Codex HIGH + DA): the post-dispatch
        // tail (`delay`) runs ONLY on the success path — the mail is DEFINITELY
        // sent — so an error there must be sentinel-marked, never an unmarked
        // error that re-enters the legacy fallback (guaranteed duplicate).
        let script = buildMailtoComposeScript(
            url: "mailto:a@b.c?subject=s", subject: "s", attachments: [], send: true)
        XCTAssertTrue(script.contains("set _dispatched to false"),
                      "flag must be initialized before the GUI try block")
        let keystroke = script.range(of: "keystroke \"d\" using {command down, shift down}")
        let flagSet = script.range(of: "set _dispatched to true")
        let tailDelay = script.range(of: "delay", range: (flagSet?.upperBound ?? script.startIndex)..<script.endIndex)
        let outerHandler = script.range(of: "on error _mErr")
        guard let k = keystroke, let f = flagSet, let d = tailDelay, let h = outerHandler else {
            return XCTFail("keystroke / flag-set / tail delay / outer handler must all be present")
        }
        XCTAssertLessThan(k.lowerBound, f.lowerBound, "flag set after the dispatch keystroke")
        XCTAssertLessThan(f.lowerBound, d.lowerBound, "tail delay after the flag set")
        XCTAssertLessThan(d.lowerBound, h.lowerBound,
                          "tail delay must sit INSIDE the outer try (before its handler)")
        XCTAssertTrue(script.contains("else if _dispatched then"),
                      "outer handler must sentinel-mark tail errors via the flag")
    }

    // MARK: Swift-side sentinel detection

    func testIsPostDispatchError_detectsSentinel() {
        let post = MailError.scriptFailed(message: "POSTDISPATCH: keystroke failed", code: -1)
        XCTAssertTrue(isPostDispatchError(post))
        let pre = MailError.scriptFailed(message: "a sheet/panel is still open on the compose window", code: -1)
        XCTAssertFalse(isPostDispatchError(pre))
        XCTAssertFalse(isPostDispatchError(MailError.scriptCreationFailed))
        // #242 verify hardening: prefix-only, symmetric with the AppleScript
        // `does not start with` check — a mid-string token (user-controlled
        // content echoed into a pre-dispatch error) must NOT classify.
        let midString = MailError.scriptFailed(message: "file 'POSTDISPATCH: evil.pdf' not found", code: -1)
        XCTAssertFalse(isPostDispatchError(midString),
                       "sentinel must match as a PREFIX only")
    }

    // MARK: router no-fallback branch

    private enum Boom: Error, LocalizedError {
        case post
        var errorDescription: String? { "POSTDISPATCH: window vanished mid-send" }
    }

    func testDispatch_postDispatchError_surfacesMappedUnknownSendState() {
        // The sentinel is carried by MailError.scriptFailed's message, not by
        // any error whose description happens to start with the token —
        // isPostDispatchError matches the case, then the prefix (#242).
        XCTAssertThrowsError(try dispatchComposePath(
            refusal: nil,
            cleanPath: {
                throw MailError.scriptFailed(
                    message: "POSTDISPATCH: window vanished mid-send", code: -1)
            },
            mapRuntimeError: { error in
                isPostDispatchError(error)
                    ? MailError.scriptFailed(
                        message: "send state UNKNOWN — check Sent/Outbox before retrying", code: -1)
                    : error
            })) { error in
            XCTAssertTrue("\(error)".contains("send state UNKNOWN"),
                          "a post-dispatch failure must surface as unknown send state")
        }
    }

    // MARK: production wiring

    func testWiring_sendCapableSitesConsultTheSentinel() throws {
        // The three send-capable sites (compose_email; reply_email and
        // forward_email since #254) consult isPostDispatchError; create_draft
        // (⌘S) must NOT — a duplicated draft is visible and harmless, and
        // gating it would only make draft creation fail more often (#301).
        let source = try ComposeDispatchTests.mailControllerSource()
        XCTAssertEqual(
            source.components(separatedBy: "isPostDispatchError").count - 1, 3,
            "exactly the three send-capable sites (composeEmail, replyEmail, forwardEmail) "
            + "consult the sentinel")
        // #301: compose also refuses to present a send-flow TIMEOUT as an
        // ordinary error — the deadline can fire on either side of ⇧⌘D.
        XCTAssertTrue(source.contains("isTimeoutError"),
                      "the send flows must classify timeouts as unknown send state (#301)")
    }
}

/// #254 — the reply/forward paste builder gets the same POSTDISPATCH
/// protection as compose (#242): sentinel on the send keystroke, `_dispatched`
/// flag on the success-path tail, cleanup skipped on unknown send state.
final class ReplyForwardSendStageTests: XCTestCase {

    override func tearDown() async throws {
        // Deterministic seam reset (verify #254 DA) — a fire-and-forget Task
        // reset is a detached mutation race on the shared actor whose safety
        // would rest only on incidental test-class ordering.
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    private func replyScript(saveAsDraft: Bool) -> String {
        buildReplyEmailPasteScript(
            messageRef: "message id 1 of mailbox \"INBOX\"",
            newBody: "hi", replyAll: false, ccAdditional: nil,
            attachments: nil, saveAsDraft: saveAsDraft)
    }

    func testReplySend_sentinelAndFlagProtectDispatchAndTail() {
        let script = replyScript(saveAsDraft: false)
        XCTAssertTrue(script.contains("set _dispatched to false"))
        XCTAssertTrue(script.contains("POSTDISPATCH: "))
        XCTAssertTrue(script.contains("else if _dispatched then"))
        let keystroke = script.range(of: "keystroke \"d\" using {command down, shift down}")
        let flagSet = script.range(of: "set _dispatched to true")
        let handler = script.range(of: "on error _mErr")
        guard let k = keystroke, let f = flagSet, let h = handler else {
            return XCTFail("dispatch, flag set and handler must all be present")
        }
        XCTAssertLessThan(k.lowerBound, f.lowerBound)
        XCTAssertLessThan(f.lowerBound, h.lowerBound)
        // tail delay must be INSIDE the outer try: between flag set and handler
        let tail = script.range(of: "delay", range: f.upperBound..<script.endIndex)
        guard let d = tail else { return XCTFail("tail delay missing") }
        XCTAssertLessThan(d.lowerBound, h.lowerBound,
                          "success-path tail must sit inside the outer try (#242 pattern)")
    }

    func testReplyDraft_noSentinel_draftCloseStillAfterTry() {
        let script = replyScript(saveAsDraft: true)
        XCTAssertFalse(script.contains("POSTDISPATCH"),
                       "draft save keeps the plain fallback — duplicate draft is visible/harmless")
        XCTAssertFalse(script.contains("_dispatched"))
        // the saved-draft window close stays AFTER end try (its own inner try;
        // a close failure must never re-enter the legacy fallback)
        guard let endTry = script.range(of: "end try"),
              let close = script.range(of: "close _cw saving yes") else {
            return XCTFail("end try and draft close must both be present")
        }
        XCTAssertLessThan(endTry.lowerBound, close.lowerBound)
    }

    func testForwardPaste_alwaysSend_carriesSentinel() {
        let script = buildForwardEmailPasteScript(
            messageRef: "message id 1 of mailbox \"INBOX\"", to: ["x@y.z"], newBody: "note")
        XCTAssertTrue(script.contains("POSTDISPATCH: "))
        XCTAssertTrue(script.contains("set _dispatched to true"))
    }

    func testReplySend_cleanupSkippedOnMarkedError() {
        let script = replyScript(saveAsDraft: false)
        XCTAssertTrue(script.contains("if _mErr starts with \"POSTDISPATCH:\" then"),
                      "handler must branch on the sentinel before the window-close cleanup")
        guard let flagBranch = script.range(of: "else if _dispatched then"),
              let cleanup = script.range(of: "close _cw saving no") else {
            return XCTFail("flag branch and cleanup must both be present")
        }
        XCTAssertLessThan(flagBranch.lowerBound, cleanup.lowerBound,
                          "cleanup must be unreachable for marked/flag errors — the window is evidence")
    }

    func testProductionSite_replyPostDispatch_refusesFallback() async throws {
        // End-to-end through the #254 seam: the paste script throws a
        // sentinel-marked error → replyEmail must REFUSE the legacy fallback
        // (runner called exactly once) and surface unknown-send-state.
        var calls = 0
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in
                calls += 1
                throw MailError.scriptFailed(message: "POSTDISPATCH: window gone mid-send", code: -1)
            },
            refusal: { nil })
        do {
            _ = try await MailController.shared.replyEmail(
                id: "123", mailbox: "INBOX", accountName: "a@b.c", body: "new text")
            XCTFail("post-dispatch reply failure must throw, not fall back")
        } catch {
            XCTAssertTrue("\(error)".contains("Sent"),
                          "unknown-send-state error must direct the user to check Sent/Outbox: \(error)")
        }
        XCTAssertEqual(calls, 1, "legacy path must NEVER run after a post-dispatch send failure")
    }
}
