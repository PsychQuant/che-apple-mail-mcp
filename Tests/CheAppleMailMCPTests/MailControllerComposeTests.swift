import XCTest
@testable import CheAppleMailMCP

final class MailControllerComposeTests: XCTestCase {

    // MARK: - Test helpers

    /// Tightens lenient `script.contains` assertions (#20 finding C). Asserts
    /// `needle` appears AFTER `before` and BEFORE `after` — defends against
    /// regressions that move a property out of its expected AppleScript
    /// section (e.g. a `set html content to ...` line that ends up after
    /// `end tell` would previously have passed `script.contains` but
    /// crashes Mail.app at runtime).
    private func assertOrdered(
        _ script: String,
        _ needle: String,
        between before: String,
        and after: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let needleR = script.range(of: needle) else {
            XCTFail("script missing required token \(needle.debugDescription)", file: file, line: line)
            return
        }
        guard let beforeR = script.range(of: before) else {
            XCTFail("script missing context anchor \(before.debugDescription)", file: file, line: line)
            return
        }
        guard let afterR = script.range(of: after) else {
            XCTFail("script missing context anchor \(after.debugDescription)", file: file, line: line)
            return
        }
        XCTAssertLessThan(beforeR.lowerBound, needleR.lowerBound,
                          "expected \(needle.debugDescription) to come AFTER \(before.debugDescription)",
                          file: file, line: line)
        XCTAssertLessThan(needleR.lowerBound, afterR.lowerBound,
                          "expected \(needle.debugDescription) to come BEFORE \(after.debugDescription)",
                          file: file, line: line)
    }

    // MARK: - appleScriptEscape

    func testAppleScriptEscape_handlesQuotesAndNewlines() {
        XCTAssertEqual(appleScriptEscape("hello"), "hello")
        XCTAssertEqual(appleScriptEscape("say \"hi\""), "say \\\"hi\\\"")
        XCTAssertEqual(
            appleScriptEscape("line1\nline2"),
            "line1\" & return & \"line2"
        )
    }

    // MARK: - buildComposeEmailScript

    // MARK: - buildCreateDraftScript

    // MARK: - composeReplyHTML (reply/forward HTML composition)

    // MARK: - composeReplyPlainText (issue #43 fix)

    // MARK: - buildReplyEmailScript

    // MARK: - buildReplyEmailScript: cc_additional / attachments / save_as_draft (issue #33)

    // MARK: - buildReplyEmailScript: window-popup behavior (issue #33 verify finding A)

    // MARK: - buildForwardEmailScript

    // MARK: - account_id messageRef propagation (#104 PR-C)
    //
    // reply_email / forward_email keep the `buildReplyEmailScript` /
    // `buildForwardEmailScript` signature unchanged (opaque `messageRef: String`).
    // The #104 account_id disambiguation happens upstream in
    // `MailController.{reply,forward}Email`, which swaps `msgRef` →
    // `resolveMsgRef`.
    //
    // SCOPE OF THESE TESTS (honest): they pin only *builder transparency* —
    // that the builder embeds whatever `messageRef` string it is handed
    // verbatim into `set originalMsg to ...`, without re-deriving or mangling
    // it. They do NOT lock the actual `msgRef → resolveMsgRef` call-site swap
    // inside `MailController` — that swap is the real #104 disambiguation
    // point but `MailController` is an `actor` whose methods shell out to
    // `osascript`, so it is not unit-testable without a live Mail.app.
    // A regression that reverted `resolveMsgRef` → `msgRef` in the controller
    // would NOT fail these tests. That coverage gap is tracked as a follow-up.

    private let prcUUID = "C38E0583-47F8-4468-BE70-43155C15549D"

    // MARK: - sanitize_links wiring contract (#85, sister of #19)
    //
    // These tests pin the END-TO-END forwarding of the `sanitizeLinks` parameter
    // from the script-builder layer down through `renderBody` to the emitted
    // AppleScript. Each test exercises both arms (default-off passthrough +
    // sanitize_links=true block) so a future regression that drops
    // `sanitizeLinks: sanitizeLinks` forwarding in any of the 5 sites
    // (compose/draft/reply/forward MailController methods + composeReplyHTML)
    // will fail at least one assertion. The unit-level
    // `MarkdownRenderingTests` already cover the algorithm; these tests cover
    // the WIRING. Verify with fault injection: set any `sanitizeLinks: ...`
    // call site to hardcoded `false` and re-run — corresponding test must fail.

    // MARK: - parseFetchedOriginalContent

    // MARK: - #131: sender account selection (compose_email / create_draft)

    /// #131: `composeEmail` MUST validate `fromAddress` at the boundary
    /// (mirrors #41 recipient validation). Control characters in sender
    /// would create a header-injection vector at the AppleScript layer.
    func testComposeEmail_rejectsControlCharsInFromAddress() async {
        do {
            _ = try await MailController.shared.composeEmail(
                to: ["x@example.com"],
                subject: "Hi",
                body: "Body",
                fromAddress: "ok@x.com\nBcc: leak@evil.com"
            )
            XCTFail("expected invalidParameter for control-char from_address")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("control characters"))
            XCTAssertTrue(msg.contains("from_address"),
                          "msg must name the from_address field: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCreateDraft_rejectsMissingAtInFromAddress() async {
        do {
            _ = try await MailController.shared.createDraft(
                to: ["x@example.com"],
                subject: "Hi",
                body: "Body",
                fromAddress: "not-an-email"
            )
            XCTFail("expected invalidParameter for malformed from_address")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("exactly one '@'"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - #134: resolveMsgRef wiring lock for reply/forward overloads

    // MARK: - #218 buildReplyEmailPasteScript (wrapper-free clean reply)
    //
    // The clean path drives Mail's NATIVE `reply` verb (Mail quotes the original
    // itself, correctly, in a `blockquote type="cite"`) and pastes ONLY the new
    // body at the cursor via System Events — NEVER `set content` / `set html
    // content` for the new body (that path is what wraps the user's text in the
    // URLShare/cite wrapper). Window identity = id-delta in the Mail model + a
    // front-window-id guard (reply compose windows have an EMPTY title, so the AX
    // layer is gated on "our window is the frontmost Mail window", never on title).

    func testBuildReplyPasteScript_usesNativeReplyVerb_pastesBody_neverInjectsContent() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "Clean reply text",
            replyAll: false, saveAsDraft: false)
        XCTAssertTrue(s.contains("reply originalMsg with opening window"),
                      "must drive Mail's native reply verb (so Mail quotes the original)")
        // THE #218 PROPERTY: the new body must NOT be injected (would re-wrap).
        XCTAssertFalse(s.contains("set content to"),
                       "paste path MUST NOT `set content` for the new body (#218 wrapper)")
        XCTAssertFalse(s.contains("set html content to"),
                       "paste path MUST NOT `set html content` for the new body (#218 wrapper)")
        // new body lands via clipboard paste at the cursor (above the native quote)
        XCTAssertTrue(s.contains("set the clipboard to \"Clean reply text\""))
        XCTAssertTrue(s.contains("keystroke \"v\" using command down"))
    }

    func testBuildReplyPasteScript_send_usesSendShortcut_andLabel() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: false, saveAsDraft: false)
        XCTAssertTrue(s.contains("keystroke \"d\" using {command down, shift down}"))
        XCTAssertFalse(s.contains("keystroke \"s\" using command down"))
        XCTAssertTrue(s.contains("Reply sent successfully (paste path)"))
    }

    func testBuildReplyPasteScript_draft_usesSaveShortcut_andLabel() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: false, saveAsDraft: true)
        XCTAssertTrue(s.contains("keystroke \"s\" using command down"))
        XCTAssertFalse(s.contains("keystroke \"d\" using {command down, shift down}"))
        XCTAssertTrue(s.contains("Reply saved as draft (paste path)"))
    }

    func testBuildReplyPasteScript_replyAll_usesReplyAllVerb() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: true, saveAsDraft: false)
        XCTAssertTrue(s.contains("reply all originalMsg with opening window"))
    }

    func testBuildReplyPasteScript_windowIdDeltaGuard_frontWindowNotTitle() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: false, saveAsDraft: false)
        // identify the window by id-delta in the Mail model and gate keystrokes on
        // "OUR window is the frontmost Mail window" (its id is in the delta set).
        // Reply compose windows have an EMPTY title (live-verified), so we must NOT
        // depend on a window title or a localized Re:/Fwd: prefix.
        XCTAssertTrue(s.contains("set _beforeIds to (id of every window)"),
                      "must snapshot window ids before the reply verb")
        XCTAssertTrue(s.contains("if _beforeIds does not contain _thisId then set end of _newIds"),
                      "must compute the new-window id delta")
        XCTAssertTrue(s.contains("if (id of front window) is not in _newIds then error"),
                      "must gate keystrokes on OUR window being the frontmost Mail window (id-based, not title)")
        XCTAssertTrue(s.contains("set frontmost to true"),
                      "must bring Mail frontmost before keystrokes")
        XCTAssertTrue(s.contains("count of sheets of window 1"),
                      "must refuse dispatch while a sheet/panel is open on the frontmost window")
        // MUST NOT depend on the window title (empty for reply windows)
        XCTAssertFalse(s.contains("name of _w"), "must NOT read the window title (empty for reply windows)")
        XCTAssertFalse(s.contains("title of _cand"), "must NOT match the AX window by title")
        XCTAssertFalse(s.contains("Re:"), "must NOT hardcode a localized reply-prefix title")
        XCTAssertFalse(s.contains("Fwd:"), "must NOT hardcode a localized forward-prefix title")
    }

    // #218 verify follow-up: the clean-path saveAsDraft must CLOSE its reply
    // window after ⌘S (the send path's ⇧⌘D closes the window itself). Otherwise
    // every quiet draft leaves a lingering compose window, and an open compose
    // window also holds the draft (blocking deletion). The close must live OUTSIDE
    // the `try` — a close failure must NOT propagate into the legacy fallback
    // (that would produce a second draft, the bug the dispatch-is-last-statement
    // ordering deliberately avoids). It closes by id (`item 1 of _newIds`) with
    // `saving yes` (harmless re-save), distinct from the on-error `saving no`.
    func testBuildReplyPasteScript_saveAsDraft_closesWindowAfterSave() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: false, saveAsDraft: true)
        // close by ITERATION + id membership (the reliable form; the `whose id is`
        // filter silently fails on compose windows). `saving yes` re-saves the
        // already-saved draft harmlessly.
        XCTAssertTrue(s.contains("if (id of _cw) is in _newIds then close _cw saving yes"),
                      "saveAsDraft must close the saved draft window by id-iteration (quiet draft)")
        // must be AFTER the try block (so a close failure can't trigger fallback)
        assertOrdered(s, "saving yes", between: "end try", and: "return")
    }

    func testBuildReplyPasteScript_send_noExplicitWindowClose() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: false, saveAsDraft: false)
        // send path: ⇧⌘D sends + closes the compose window itself — no `saving yes` close.
        XCTAssertFalse(s.contains("saving yes"),
                       "send path must not add an explicit draft-window close (⇧⌘D closes it)")
    }

    func testBuildForwardPasteScript_send_noExplicitWindowClose() {
        // forward always sends → no explicit close (matches reply send path).
        let s = buildForwardEmailPasteScript(
            messageRef: "msgRef", to: ["x@y.z"], newBody: "B")
        XCTAssertFalse(s.contains("saving yes"))
    }

    func testBuildReplyPasteScript_onError_closesOnlyNewWindows_noDataLoss() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: false, saveAsDraft: false)
        XCTAssertTrue(s.contains("on error _mErr"))
        // cleanup closes ONLY windows we created (id membership), never a
        // pre-existing user window — and must NOT batch-close by title (data-loss
        // bug, #175 r2). `saving no` discards the abandoned compose.
        XCTAssertTrue(s.contains("if (id of _cw) is in _newIds then close _cw saving no"))
        XCTAssertFalse(s.contains("close (every window whose name"))
    }

    func testBuildReplyPasteScript_ccAndAttachments_setNativelyAfterPaste() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: false,
            ccAdditional: ["x@y.z"], attachments: ["/tmp/a.pdf"], saveAsDraft: false)
        // cc / attachments are set on the reply message object natively (unchanged
        // from #34/#60), inside `tell replyMsg`, AFTER the body paste so the
        // body-top cursor is undisturbed.
        assertOrdered(s, "make new cc recipient", between: "tell replyMsg", and: "on error _mErr")
        assertOrdered(s, "make new attachment", between: "tell replyMsg", and: "on error _mErr")
        XCTAssertTrue(s.contains("address:\"x@y.z\""))
        XCTAssertTrue(s.contains("POSIX file \"/tmp/a.pdf\""))
        // paste must come before the native object mutations (cursor safety)
        assertOrdered(s, "keystroke \"v\" using command down",
                      between: "reply originalMsg with opening window", and: "make new cc recipient")
    }

    func testBuildReplyPasteScript_noCcNoAttachments_omitsTellReplyMsgBlock() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "B", replyAll: false, saveAsDraft: false)
        XCTAssertFalse(s.contains("make new cc recipient"))
        XCTAssertFalse(s.contains("make new attachment"))
    }

    func testBuildReplyPasteScript_escapesBodyQuotes() {
        let s = buildReplyEmailPasteScript(
            messageRef: "msgRef", newBody: "say \"hi\"", replyAll: false, saveAsDraft: false)
        XCTAssertTrue(s.contains("set the clipboard to \"say \\\"hi\\\"\""))
    }

    func testBuildReplyPasteScript_embedsMessageRefVerbatim() {
        let uuidRef = resolveMsgRef(id: "42", mailbox: "INBOX",
                                    accountId: "C38E0583-47F8-4468-BE70-43155C15549D",
                                    accountName: "alice@example.com")
        let s = buildReplyEmailPasteScript(
            messageRef: uuidRef, newBody: "B", replyAll: false, saveAsDraft: false)
        XCTAssertTrue(s.contains("(account id \"C38E0583-47F8-4468-BE70-43155C15549D\")"),
                      "messageRef must be embedded verbatim into `set originalMsg to`")
        XCTAssertTrue(s.contains("set originalMsg to (first message"))
    }

    // MARK: - #218 buildForwardEmailPasteScript (wrapper-free clean forward)

    func testBuildForwardPasteScript_usesNativeForwardVerb_pastesBody_neverInjectsContent() {
        let s = buildForwardEmailPasteScript(
            messageRef: "msgRef", to: ["x@y.z"], newBody: "Clean forward note")
        XCTAssertTrue(s.contains("forward originalMsg with opening window"))
        XCTAssertFalse(s.contains("set content to"),
                       "paste path MUST NOT `set content` for the new body (#218 wrapper)")
        XCTAssertFalse(s.contains("set html content to"))
        XCTAssertTrue(s.contains("set the clipboard to \"Clean forward note\""))
        XCTAssertTrue(s.contains("keystroke \"v\" using command down"))
    }

    func testBuildForwardPasteScript_send_usesSendShortcut_andLabel() {
        let s = buildForwardEmailPasteScript(
            messageRef: "msgRef", to: ["x@y.z"], newBody: "B")
        XCTAssertTrue(s.contains("keystroke \"d\" using {command down, shift down}"))
        XCTAssertTrue(s.contains("Email forwarded successfully (paste path)"))
    }

    func testBuildForwardPasteScript_toRecipientsSetNatively() {
        let s = buildForwardEmailPasteScript(
            messageRef: "msgRef", to: ["a@b.c", "d@e.f"], newBody: "B")
        assertOrdered(s, "make new to recipient", between: "tell fwdMsg", and: "on error _mErr")
        XCTAssertTrue(s.contains("address:\"a@b.c\""))
        XCTAssertTrue(s.contains("address:\"d@e.f\""))
    }

    func testBuildForwardPasteScript_windowIdDeltaGuard_frontWindowNotTitle() {
        let s = buildForwardEmailPasteScript(
            messageRef: "msgRef", to: ["x@y.z"], newBody: "B")
        XCTAssertTrue(s.contains("set _beforeIds to (id of every window)"))
        XCTAssertTrue(s.contains("if (id of front window) is not in _newIds then error"))
        XCTAssertTrue(s.contains("on error _mErr"))
        XCTAssertFalse(s.contains("name of _w"))
        XCTAssertFalse(s.contains("Fwd:"))
    }

    // MARK: - validateEmailAddresses (#41)

    func testValidateEmailAddresses_acceptsValid() async throws {
        try await MailController.shared.validateEmailAddresses(
            ["a@b.com", "user.name+tag@example.co.uk", "用戶@xn--wgv71a.com"],
            field: "to"
        )
    }

    func testValidateEmailAddresses_emptyArrayIsNoop() async throws {
        try await MailController.shared.validateEmailAddresses([], field: "cc")
    }

    func testValidateEmailAddresses_rejectsControlChars() async {
        // Header injection attempt: \n in address could try to inject Bcc: header.
        do {
            try await MailController.shared.validateEmailAddresses(
                ["ok@x.com\nBcc: leak@evil.com"],
                field: "cc_additional"
            )
            XCTFail("expected control-char rejection")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("control characters"), "msg must mention control chars: \(msg)")
            XCTAssertTrue(msg.contains("cc_additional"), "msg must include field name: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testValidateEmailAddresses_rejectsMissingAt() async {
        do {
            try await MailController.shared.validateEmailAddresses(["not-an-email"], field: "to")
            XCTFail("expected reject")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("exactly one '@'"), "msg must explain: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - validateAttachmentPaths (#38)

    /// Helper to assert validation throws MailError.invalidParameter with a recognizable fragment.
    private func assertAttachmentRejected(_ paths: [String],
                                          containing fragment: String,
                                          envAllowList: String? = nil,
                                          file: StaticString = #file, line: UInt = #line) async {
        if let env = envAllowList {
            setenv("MAIL_MCP_ATTACHMENT_ROOTS", env, 1)
            addTeardownBlock { unsetenv("MAIL_MCP_ATTACHMENT_ROOTS") }
        }
        do {
            try await MailController.shared.validateAttachmentPaths(paths)
            XCTFail("expected validation to throw, paths=\(paths)", file: file, line: line)
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected MailError.invalidParameter, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(msg.contains(fragment),
                          "error '\(msg)' must contain '\(fragment)'",
                          file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertAttachmentAccepted(_ paths: [String],
                                          envAllowList: String? = nil,
                                          file: StaticString = #file, line: UInt = #line) async {
        if let env = envAllowList {
            setenv("MAIL_MCP_ATTACHMENT_ROOTS", env, 1)
            addTeardownBlock { unsetenv("MAIL_MCP_ATTACHMENT_ROOTS") }
        }
        do {
            try await MailController.shared.validateAttachmentPaths(paths)
        } catch {
            XCTFail("expected validation to accept paths=\(paths), got error: \(error)",
                    file: file, line: line)
        }
    }

    func testValidateAttachmentPaths_emptyArrayIsNoop() async throws {
        // Defensive: empty array short-circuits, no env var lookup, no FileManager hit.
        try await MailController.shared.validateAttachmentPaths([])
    }

    func testValidateAttachmentPaths_acceptsRegularTempFile() async throws {
        let tmp = "/tmp/che-apple-mail-test-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data("ok".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        await assertAttachmentAccepted([tmp])
    }

    func testValidateAttachmentPaths_rejectsNonexistent() async {
        let bogus = "/tmp/does-not-exist-\(UUID().uuidString).pdf"
        await assertAttachmentRejected([bogus], containing: "not found")
    }

    func testValidateAttachmentPaths_rejectsSshDirectory() async throws {
        // We can't rely on actual ~/.ssh/id_ed25519 existing in test env. Create a
        // probe file in HOME/.ssh and assert deny-list catches it. If HOME/.ssh
        // doesn't exist or isn't writable, fall back to asserting that any path
        // _under_ ~/.ssh would be rejected (helper compares prefix, file existence
        // is checked first so we need a real file).
        let home = NSHomeDirectory()
        let sshProbe = "\(home)/.ssh/che-apple-mail-test-probe-\(UUID().uuidString).txt"
        // Try to create — if can't, skip
        let parent = "\(home)/.ssh"
        guard FileManager.default.isWritableFile(atPath: parent) ||
              ((try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)) != nil),
              FileManager.default.createFile(atPath: sshProbe, contents: Data("probe".utf8)) else {
            throw XCTSkip("Cannot create probe file under ~/.ssh in test env")
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: sshProbe) }
        await assertAttachmentRejected([sshProbe], containing: ".ssh")
    }

    func testValidateAttachmentPaths_rejectsSystemPath() async {
        // /etc/hosts always exists on macOS; under deny-list "/etc".
        await assertAttachmentRejected(["/etc/hosts"], containing: "/etc")
    }

    func testValidateAttachmentPaths_resolvesSymlinkBeforeCheck() async throws {
        // Create symlink in /tmp pointing to /etc/hosts (deny-listed).
        // Without symlink resolution, the path "/tmp/symlink" looks safe (under /tmp)
        // and bypasses deny-list. With resolution, the resolved path is /etc/hosts
        // and gets rejected.
        let symlink = "/tmp/che-apple-mail-test-symlink-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: "/etc/hosts")
        addTeardownBlock { try? FileManager.default.removeItem(atPath: symlink) }
        await assertAttachmentRejected([symlink], containing: "/etc")
    }

    func testValidateAttachmentPaths_envAllowList_acceptsAllowed() async throws {
        let tmp = "/tmp/che-apple-mail-allow-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data("ok".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        await assertAttachmentAccepted([tmp], envAllowList: "/tmp")
    }

    func testValidateAttachmentPaths_envAllowList_rejectsOutsideAllowed() async throws {
        // /tmp is not in env allow-list "/var/folders" — should reject even though
        // /tmp itself isn't deny-listed.
        let tmp = "/tmp/che-apple-mail-deny-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data("ok".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        await assertAttachmentRejected([tmp], containing: "MAIL_MCP_ATTACHMENT_ROOTS",
                                        envAllowList: "/Users/nonexistent-allow-root")
    }

    func testValidateAttachmentPaths_multiplePaths_collectsAllFailures() async {
        // /etc/hosts (system deny) + bogus nonexistent. Both should be in error msg.
        let bogus = "/tmp/missing-\(UUID().uuidString).pdf"
        do {
            try await MailController.shared.validateAttachmentPaths(["/etc/hosts", bogus])
            XCTFail("expected validation to throw")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected MailError.invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("/etc"), "msg must mention /etc rejection: \(msg)")
            XCTAssertTrue(msg.contains("not found"), "msg must mention bogus path not found: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - validateEmailAddresses (#41) — continued

    func testValidateEmailAddresses_rejectsMultipleAt() async {
        do {
            try await MailController.shared.validateEmailAddresses(["a@b@c.com"], field: "to")
            XCTFail("expected reject")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else { return XCTFail() }
            XCTAssertTrue(msg.contains("exactly one '@'"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testValidateEmailAddresses_rejectsAtAtBoundaries() async {
        for bogus in ["@nodomain.com", "noprefix@", "@", ""] {
            do {
                try await MailController.shared.validateEmailAddresses([bogus], field: "to")
                XCTFail("expected reject for '\(bogus)'")
            } catch is MailError {
                // expected
            } catch {
                XCTFail("unexpected error type for '\(bogus)': \(error)")
            }
        }
    }

    func testValidateEmailAddresses_collectsAllFailures() async {
        do {
            try await MailController.shared.validateEmailAddresses(
                ["a@b@c.com", "valid@x.com", "bad"],
                field: "to"
            )
            XCTFail("expected reject")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else { return XCTFail() }
            // Both invalid addresses should appear in error message; valid one should not.
            XCTAssertTrue(msg.contains("a@b@c.com"), "msg must list a@b@c.com: \(msg)")
            XCTAssertTrue(msg.contains("'bad'"), "msg must list 'bad': \(msg)")
            XCTAssertFalse(msg.contains("'valid@x.com'"), "msg must NOT list valid address: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - redirectEmail boundary validation (#133)

    /// #133: redirect_email must run the same #41 boundary validation as
    /// compose/reply/forward. Pre-fix it skipped the check, letting malformed
    /// addresses reach Mail.app and surface as opaque AppleScript errors
    /// instead of a clean MailError.invalidParameter. The test passes an
    /// invalid recipient — validation MUST throw before any AppleScript
    /// dispatch attempt (we do not run on a CI worker that talks to Mail.app).
    func testRedirectEmail_rejectsControlCharsInRecipient() async {
        do {
            _ = try await MailController.shared.redirectEmail(
                id: "1", mailbox: "INBOX", accountName: "alice@example.com",
                to: ["ok@x.com\nBcc: leak@evil.com"], accountId: nil
            )
            XCTFail("expected invalidParameter for control-char recipient")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("control characters"),
                          "msg must mention control chars: \(msg)")
            XCTAssertTrue(msg.contains("to"),
                          "msg must include field name 'to': \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRedirectEmail_rejectsMissingAt() async {
        do {
            _ = try await MailController.shared.redirectEmail(
                id: "1", mailbox: "INBOX", accountName: "alice@example.com",
                to: ["not-an-email"], accountId: nil
            )
            XCTFail("expected invalidParameter for malformed recipient")
        } catch let error as MailError {
            guard case .invalidParameter(let msg) = error else {
                XCTFail("expected invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("exactly one '@'"),
                          "msg must explain '@' rule: \(msg)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - dedupAddresses (#34)

    func testDedupAddresses_removesCaseInsensitiveDuplicates() async {
        let result = await MailController.shared.dedupAddresses(
            ["a@b.com", "A@B.COM", "c@d.com", "a@b.com"]
        )
        XCTAssertEqual(result, ["a@b.com", "c@d.com"], "first-seen wins; case-insensitive dedup")
    }

    func testDedupAddresses_emptyArray() async {
        let result = await MailController.shared.dedupAddresses([])
        XCTAssertEqual(result, [])
    }

    func testDedupAddresses_singleAddress() async {
        let result = await MailController.shared.dedupAddresses(["a@b.com"])
        XCTAssertEqual(result, ["a@b.com"])
    }

    func testDedupAddresses_preservesFirstSeenOrder() async {
        // Order matters for downstream recipientFragment generation.
        let result = await MailController.shared.dedupAddresses(
            ["c@d.com", "a@b.com", "C@D.com", "b@e.com"]
        )
        XCTAssertEqual(result, ["c@d.com", "a@b.com", "b@e.com"])
    }

    // MARK: - Large originalPlain script size (#49)

    // MARK: - attachmentFragment race-condition mitigation (issue #60)

    // MARK: - #61 indent parity (helper-owns-indent contract)

    // MARK: - #63 attachment count cap

    func testValidateAttachmentPaths_rejectsCountAboveCap() async throws {
        let paths = (1...51).map { "/tmp/file\($0).txt" }
        do {
            try await MailController.shared.validateAttachmentPaths(paths)
            XCTFail("expected throw on count > 50")
        } catch MailError.invalidParameter(let msg) {
            XCTAssertTrue(msg.contains("exceeds cap"), "error message should mention 'exceeds cap'")
            XCTAssertTrue(msg.contains("51"), "error message should mention actual count")
        } catch {
            XCTFail("expected MailError.invalidParameter, got \(error)")
        }
    }

    func testValidateAttachmentPaths_acceptsCountAtCap() async {
        // 50 paths is at the boundary — must NOT throw on count alone.
        // (existence check will throw because /tmp/file<n>.txt don't exist,
        // but that's a different code path; we just want to verify count
        // gate doesn't reject 50.)
        let paths = (1...50).map { "/tmp/file\($0).txt" }
        do {
            try await MailController.shared.validateAttachmentPaths(paths)
            XCTFail("validateAttachmentPaths should fail on missing files (existence layer), not count")
        } catch MailError.invalidParameter(let msg) {
            XCTAssertFalse(msg.contains("exceeds cap"), "count cap should not fire at exactly 50 paths; got: \(msg)")
            // Existence-layer failure is the expected path here.
            XCTAssertTrue(msg.contains("not found"), "expected existence failure, got: \(msg)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - #64 env-configurable attachment delays

}
