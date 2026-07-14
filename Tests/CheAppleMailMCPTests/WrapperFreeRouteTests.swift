import XCTest
@testable import CheAppleMailMCP

/// #241 — regression-lock for the #237/#229 disclosure WIRING. The pure
/// helpers (`mailtoIneligibilityReason`, `legacyPathDisclosure`, …) were
/// already pinned, but the control flow that calls them lived inline in a
/// singleton actor and had zero non-live coverage: deleting the wiring kept
/// the whole suite green. `routeWrapperFreeCompose` extracts that control
/// flow behind injectable closures so these tests can drive all branches.
final class WrapperFreeRouteTests: XCTestCase {

    private enum Boom: Error, LocalizedError {
        case gui(String)
        var errorDescription: String? {
            if case .gui(let m) = self { return m }
            return "boom"
        }
    }

    /// Route call with spy closures; returns (result, warnsIneligible,
    /// warnsFailed, cleanCalls, legacyCalls).
    private func drive(
        reason: String?,
        clean: @escaping () throws -> String,
        legacy: @escaping () throws -> String = { "Legacy OK" }
    ) throws -> (result: String, ineligibleWarns: [String], failedWarns: [String],
                 cleanCalls: Int, legacyCalls: Int) {
        var ineligibleWarns: [String] = []
        var failedWarns: [String] = []
        var cleanCalls = 0
        var legacyCalls = 0
        let result = try routeWrapperFreeCompose(
            ineligibilityReason: reason,
            cleanPath: { cleanCalls += 1; return try clean() },
            legacyPath: { legacyCalls += 1; return try legacy() },
            disclosure: { legacyPathDisclosure(reason: $0) },
            warnIneligible: { ineligibleWarns.append($0) },
            warnTriedAndFailed: { failedWarns.append($0.localizedDescription) },
            fallbackReason: { "mailto GUI path failed: \(clampedErrorEcho($0.localizedDescription))" })
        return (result, ineligibleWarns, failedWarns, cleanCalls, legacyCalls)
    }

    func testEligible_cleanSucceeds_noSuffix_noWarns_legacyNeverRuns() throws {
        let r = try drive(reason: nil, clean: { "Draft created successfully" })
        XCTAssertEqual(r.result, "Draft created successfully",
                       "clean-path result must carry NO legacy disclosure suffix")
        XCTAssertFalse(r.result.contains("[legacy path"))
        XCTAssertTrue(r.ineligibleWarns.isEmpty)
        XCTAssertTrue(r.failedWarns.isEmpty)
        XCTAssertEqual(r.cleanCalls, 1)
        XCTAssertEqual(r.legacyCalls, 0)
    }

    func testEligible_cleanThrows_warnsOnce_legacyResultCarriesClampedReason() throws {
        let r = try drive(reason: nil, clean: { throw Boom.gui("window vanished\nline2") })
        XCTAssertEqual(r.failedWarns.count, 1, "tried-and-failed warn fires exactly once")
        XCTAssertTrue(r.ineligibleWarns.isEmpty, "ineligible warn must NOT fire on the tried branch")
        XCTAssertEqual(r.legacyCalls, 1)
        XCTAssertTrue(r.result.hasPrefix("Legacy OK"))
        XCTAssertTrue(r.result.contains("Reason: mailto GUI path failed: window vanished line2."),
                      "suffix must name the reason with the newline-folded (clamped) error echo: \(r.result)")
        XCTAssertFalse(r.result.contains("\n"), "clamped echo keeps the suffix single-line")
    }

    func testIneligible_warnsOnce_cleanNeverRuns_suffixNamesReason() throws {
        let reason = "custom from_address forces the legacy path until #219"
        let r = try drive(reason: reason, clean: { XCTFail("clean path must not run"); return "" })
        XCTAssertEqual(r.ineligibleWarns, [reason], "ineligible warn fires exactly once with the named reason")
        XCTAssertTrue(r.failedWarns.isEmpty)
        XCTAssertEqual(r.cleanCalls, 0)
        XCTAssertEqual(r.legacyCalls, 1)
        XCTAssertTrue(r.result.contains("Reason: \(reason)."),
                      "suffix must carry the ineligibility reason verbatim: \(r.result)")
    }

    func testLegacyThrow_propagates_fromBothBranches() {
        XCTAssertThrowsError(try drive(reason: "some reason",
                                       clean: { "" },
                                       legacy: { throw Boom.gui("legacy died") }))
        XCTAssertThrowsError(try drive(reason: nil,
                                       clean: { throw Boom.gui("clean died") },
                                       legacy: { throw Boom.gui("legacy died") }))
    }

    func testClampIntegration_longMultilineErrorBounded() throws {
        let longError = String(repeating: "x", count: 500) + "\r\n" + String(repeating: "y", count: 500)
        let r = try drive(reason: nil, clean: { throw Boom.gui(longError) })
        let suffix = r.result.dropFirst("Legacy OK".count)
        // legacyPathDisclosure's fixed boilerplate is ~330 chars; the clamped
        // echo adds at most ~200 more. 1000-char input must not reach 600.
        XCTAssertLessThan(suffix.count, 600,
                          "clamped echo caps the disclosure suffix length: \(suffix.count) chars")
        XCTAssertFalse(suffix.contains("\n"))
        XCTAssertFalse(suffix.contains("\r"))
    }

    func testWiring_allFourCallSitesRouteThroughTheRouter() throws {
        // The actual #241 target: the WIRING must not be deletable while the
        // suite stays green. Pin all four compose-family call sites onto the
        // router (compose_email, create_draft, reply_email, forward_email).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let count = source.components(separatedBy: "try routeWrapperFreeCompose(").count - 1
        XCTAssertEqual(count, 4,
                       "expected compose/createDraft/reply/forward to route via routeWrapperFreeCompose; found \(count)")
        XCTAssertFalse(source.contains("var legacyReason"),
                       "inline wiring must be gone — replaced by the router (#241)")
        XCTAssertFalse(source.contains("var legacyReplyReason"))
        XCTAssertFalse(source.contains("var legacyForwardReason"))
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

    func testRouter_shouldFallbackFalse_rethrowsMapped_neverRunsLegacy() {
        var legacyCalls = 0
        var failedWarns = 0
        XCTAssertThrowsError(try routeWrapperFreeCompose(
            ineligibilityReason: nil,
            cleanPath: { throw Boom.post },
            legacyPath: { legacyCalls += 1; return "Legacy OK" },
            disclosure: { _ in "" },
            warnIneligible: { _ in },
            warnTriedAndFailed: { _ in failedWarns += 1 },
            fallbackReason: { _ in "unused" },
            shouldFallback: { _ in false },
            mapNoFallbackError: { _ in
                MailError.scriptFailed(message: "send state UNKNOWN — check Sent/Outbox before retrying", code: -1)
            })) { error in
            XCTAssertTrue("\(error)".contains("send state UNKNOWN"),
                          "no-fallback branch must surface the mapped unknown-send-state error")
        }
        XCTAssertEqual(legacyCalls, 0, "legacy path must NEVER run when fallback is refused")
        XCTAssertEqual(failedWarns, 0, "the tried-and-failed fallback warn must not fire on the refused branch")
    }

    func testRouter_shouldFallbackDefaultsTrue_existingBehaviorUnchanged() throws {
        var legacyCalls = 0
        let result = try routeWrapperFreeCompose(
            ineligibilityReason: nil,
            cleanPath: { throw Boom.post },
            legacyPath: { legacyCalls += 1; return "Legacy OK" },
            disclosure: { " [\($0)]" },
            warnIneligible: { _ in },
            warnTriedAndFailed: { _ in },
            fallbackReason: { _ in "reason" })
        XCTAssertEqual(legacyCalls, 1)
        XCTAssertTrue(result.hasPrefix("Legacy OK"))
    }

    // MARK: production wiring

    func testWiring_composeEmailRefusesPostDispatchFallback() throws {
        // The three send-capable sites (compose_email; reply_email and
        // forward_email since #254) consult isPostDispatchError; create_draft
        // (⌘S) must NOT — a duplicated draft is visible and harmless.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("shouldFallback: { !isPostDispatchError($0) }"),
                      "composeEmail must refuse legacy fallback for post-dispatch send errors (#242)")
        XCTAssertEqual(
            source.components(separatedBy: "isPostDispatchError").count - 1, 3,
            "the three send-capable sites (composeEmail, replyEmail, forwardEmail) consult the sentinel (#254)")
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
        await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil)
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
            ineligibility: { nil })
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
