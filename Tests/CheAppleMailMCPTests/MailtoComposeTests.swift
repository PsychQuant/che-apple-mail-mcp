import XCTest
@testable import CheAppleMailMCP

/// #175 — mailto-based clean-body compose. The wrapper-free path requires
/// building a percent-encoded `mailto:` URL (native compose pipeline) and
/// deciding when the GUI path is usable vs. when to fall back to the legacy
/// AppleScript injection (which produces the `blockquote type="cite"` wrapper).
/// The URL builder and the decision are pure → unit-tested here; the GUI
/// orchestration is gated/live-tested elsewhere.
final class MailtoComposeTests: XCTestCase {

    // MARK: - buildMailtoURL

    func testBuildMailtoURL_singleRecipient_plainBody() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "Hi", body: "Hello")
        XCTAssertEqual(url, "mailto:a%40b.c?subject=Hi&body=Hello")
    }

    func testBuildMailtoURL_multipleRecipients_commaJoined() {
        let url = buildMailtoURL(to: ["a@b.c", "d@e.f"], subject: "S", body: "B")
        XCTAssertTrue(url.hasPrefix("mailto:a%40b.c,d%40e.f?"),
                      "recipients should be comma-joined in the path: \(url)")
    }

    func testBuildMailtoURL_ccAndBcc_asQueryParams() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B",
                                 cc: ["c@d.e"], bcc: ["x@y.z"])
        XCTAssertTrue(url.contains("cc=c%40d.e"), "missing cc: \(url)")
        XCTAssertTrue(url.contains("bcc=x%40y.z"), "missing bcc: \(url)")
    }

    func testBuildMailtoURL_emptyCcBcc_omitted() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B",
                                 cc: [], bcc: nil)
        XCTAssertFalse(url.contains("cc="), "empty cc must be omitted: \(url)")
        XCTAssertFalse(url.contains("bcc="), "nil bcc must be omitted: \(url)")
    }

    func testBuildMailtoURL_percentEncodesSpacesNewlinesAndCJK() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "two words",
                                 body: "line1\nline2 中文")
        // space -> %20, newline -> %0A, CJK -> %E4..., and no raw delimiter leaks
        XCTAssertTrue(url.contains("subject=two%20words"), url)
        XCTAssertTrue(url.contains("body=line1%0Aline2%20"), url)
        XCTAssertTrue(url.contains("%E4%B8%AD%E6%96%87"), "CJK must be percent-encoded: \(url)")
        XCTAssertFalse(url.contains(" "), "no raw spaces allowed: \(url)")
        XCTAssertFalse(url.contains("\n"), "no raw newlines allowed: \(url)")
    }

    func testBuildMailtoURL_doesNotLeakAmpersandFromBodyIntoQuery() {
        // A literal & in the body must be encoded so it can't be parsed as a
        // query-param separator (would corrupt the mailto).
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "A & B")
        XCTAssertTrue(url.contains("body=A%20%26%20B"), url)
        // exactly one '&' separator (between subject and body params)
        XCTAssertEqual(url.filter { $0 == "&" }.count, 1, "stray & leaked: \(url)")
    }

    // MARK: - shouldUseMailtoCompose (fallback decision)

    func testShouldUseMailto_plain_trusted_enabled_noCustomSender_withSubject_true() {
        XCTAssertTrue(shouldUseMailtoCompose(format: .plain,
                                             accessibilityTrusted: true,
                                             disabledByEnv: false,
                                             hasCustomSender: false,
                                             hasSubject: true))
    }

    func testShouldUseMailto_htmlFormat_false() {
        // mailto is plain-only — markdown/html MUST use the legacy path.
        XCTAssertFalse(shouldUseMailtoCompose(format: .html,
                                              accessibilityTrusted: true,
                                              disabledByEnv: false,
                                              hasCustomSender: false,
                                              hasSubject: true))
        XCTAssertFalse(shouldUseMailtoCompose(format: .markdown,
                                              accessibilityTrusted: true,
                                              disabledByEnv: false,
                                              hasCustomSender: false,
                                              hasSubject: true))
    }

    func testShouldUseMailto_noAccessibility_false() {
        XCTAssertFalse(shouldUseMailtoCompose(format: .plain,
                                              accessibilityTrusted: false,
                                              disabledByEnv: false,
                                              hasCustomSender: false,
                                              hasSubject: true))
    }

    func testShouldUseMailto_disabledByEnv_false() {
        XCTAssertFalse(shouldUseMailtoCompose(format: .plain,
                                              accessibilityTrusted: true,
                                              disabledByEnv: true,
                                              hasCustomSender: false,
                                              hasSubject: true))
    }

    func testShouldUseMailto_customSender_false() {
        // mailto can't pick a non-default account → legacy path handles sender.
        XCTAssertFalse(shouldUseMailtoCompose(format: .plain,
                                              accessibilityTrusted: true,
                                              disabledByEnv: false,
                                              hasCustomSender: true,
                                              hasSubject: true))
    }

    func testShouldUseMailto_emptySubject_false() {
        // No subject → no window-title to identify the dispatch target → legacy.
        XCTAssertFalse(shouldUseMailtoCompose(format: .plain,
                                              accessibilityTrusted: true,
                                              disabledByEnv: false,
                                              hasCustomSender: false,
                                              hasSubject: false))
    }

    // MARK: - mailtoComposeDisabledByEnv

    func testDisabledByEnv_detectsTruthyValues() {
        XCTAssertTrue(mailtoComposeDisabledByEnv([mailtoComposeDisableEnvKey: "1"]))
        XCTAssertTrue(mailtoComposeDisabledByEnv([mailtoComposeDisableEnvKey: "true"]))
        XCTAssertTrue(mailtoComposeDisabledByEnv([mailtoComposeDisableEnvKey: "YES"]))
        XCTAssertFalse(mailtoComposeDisabledByEnv([mailtoComposeDisableEnvKey: "0"]))
        XCTAssertFalse(mailtoComposeDisabledByEnv([:]))
    }

    // MARK: - buildMailtoComposeScript (GUI orchestration structure)

    func testMailtoScript_send_usesSendShortcut_andWindowIdentityGuard() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B")
        let s = buildMailtoComposeScript(url: url, subject: "S", attachments: [], send: true)
        // dispatch = ⇧⌘D (send), not ⌘S
        XCTAssertTrue(s.contains("keystroke \"d\" using {command down, shift down}"), s)
        XCTAssertFalse(s.contains("keystroke \"s\" using command down"), s)
        XCTAssertTrue(s.contains("Email sent successfully (mailto path)"))
        XCTAssertTrue(s.contains(url))
        // window-count first gate + window-IDENTITY guard (#175 verify hardening):
        XCTAssertTrue(s.contains("count of windows"), "missing window-count first gate")
        XCTAssertTrue(s.contains("if title of _cand is _t then"),
                      "dispatch must locate the compose window by title (= subject)")
        XCTAssertTrue(s.contains("if _w is missing value then error"),
                      "must hard-error (→ fallback) when our compose window isn't found")
        XCTAssertTrue(s.contains("perform action \"AXRaise\" of _w"),
                      "must raise OUR compose window before dispatch (wrong-window mitigation)")
        XCTAssertTrue(s.contains("count of sheets of _w) is not 0"),
                      "must refuse dispatch while an open panel/sheet is up on the target window")
        // stage-aware fallback with NO data loss: on error, close ONLY a window
        // we created (new id captured before mailto) AND matching subject —
        // never a pre-existing same-titled user draft (#175 verify round 2).
        XCTAssertTrue(s.contains("on error _mErr"))
        XCTAssertTrue(s.contains("set _beforeIds to (id of every window)"),
                      "must snapshot window ids before mailto for safe cleanup")
        XCTAssertTrue(s.contains("if (name of _cw) is \"S\" then close _cw saving no"),
                      "cleanup must close only our new + same-subject window, not every same-titled window")
        XCTAssertFalse(s.contains("close (every window whose name"),
                       "must NOT batch-close by subject (data-loss bug)")
    }

    func testMailtoScript_draft_usesSaveShortcut() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B")
        let s = buildMailtoComposeScript(url: url, subject: "S", attachments: [], send: false)
        XCTAssertTrue(s.contains("keystroke \"s\" using command down"), s)
        XCTAssertFalse(s.contains("keystroke \"d\" using {command down, shift down}"), s)
        XCTAssertTrue(s.contains("Draft created successfully (mailto path)"))
    }

    func testMailtoScript_noAttachments_omitsAttachAndClipboardAndDrain() {
        let s = buildMailtoComposeScript(url: "mailto:a%40b.c", subject: "S",
                                         attachments: [], send: false)
        // ⇧⌘A is the Attach shortcut — must be absent with no attachments
        XCTAssertFalse(s.contains("keystroke \"a\" using {command down, shift down}"), s)
        // no per-attachment clipboard set, no attachment drain delay
        XCTAssertFalse(s.contains("set the clipboard to"), s)
    }

    func testMailtoScript_attachments_oneAttachCyclePerFile_drain_localeIndependent() {
        let s = buildMailtoComposeScript(url: "mailto:a%40b.c", subject: "S",
                                         attachments: ["/tmp/a.pdf", "/tmp/b.txt"], send: false)
        // one File▸Attach (⇧⌘A) per attachment
        let attachCount = s.components(separatedBy: "keystroke \"a\" using {command down, shift down}").count - 1
        XCTAssertEqual(attachCount, 2, "expected one ⇧⌘A per attachment: \(s)")
        // go-to-folder (⇧⌘G); both paths set on clipboard for paste
        XCTAssertTrue(s.contains("keystroke \"g\" using {command down, shift down}"))
        XCTAssertTrue(s.contains("set the clipboard to \"/tmp/a.pdf\""))
        XCTAssertTrue(s.contains("set the clipboard to \"/tmp/b.txt\""))
        // clipboard save/restore is now the caller's job (Swift NSPasteboard) — NOT in the script
        XCTAssertFalse(s.contains("_savedClip"), "script must not do its own clipboard save/restore (#175 verify)")
        // attachment drain before dispatch (don't ⇧⌘D before attachment binds)
        XCTAssertTrue(s.contains("CHE_MAIL_MAILTO_ATTACH_DRAIN") || s.range(of: "delay") != nil)
        // locale-independence: no hardcoded localized menu names (the #174 trap)
        XCTAssertFalse(s.contains("附加檔案"))
        XCTAssertFalse(s.contains("Attach"))
    }

    func testMailtoScript_subjectWithQuotes_escapedInTitleGuardAndClose() {
        let s = buildMailtoComposeScript(url: "mailto:a%40b.c",
                                         subject: "say \"hi\"", attachments: [], send: false)
        // subject is escaped wherever it's embedded (title compare + on-error close)
        XCTAssertTrue(s.contains("say \\\"hi\\\""), s)
    }

    // MARK: - #218 shouldUsePasteReplyForward (clean reply/forward fallback decision)
    //
    // Reply/forward have the same wrapper bug as #175 compose, but the fix drives
    // Mail's NATIVE `reply`/`forward` verb (Mail quotes the original itself) and
    // pastes only the NEW body at the cursor — never `set content`/`set html
    // content`. The clean path is plain-only + needs Accessibility (GUI paste),
    // and an env hatch can force the legacy injection path.

    func testShouldUsePasteReplyForward_plain_trusted_enabled_true() {
        XCTAssertTrue(shouldUsePasteReplyForward(format: .plain,
                                                 accessibilityTrusted: true,
                                                 disabledByEnv: false))
    }

    func testShouldUsePasteReplyForward_htmlOrMarkdown_false() {
        // paste path carries plain text only — markdown/html keep the legacy path.
        XCTAssertFalse(shouldUsePasteReplyForward(format: .html,
                                                  accessibilityTrusted: true,
                                                  disabledByEnv: false))
        XCTAssertFalse(shouldUsePasteReplyForward(format: .markdown,
                                                  accessibilityTrusted: true,
                                                  disabledByEnv: false))
    }

    func testShouldUsePasteReplyForward_noAccessibility_false() {
        XCTAssertFalse(shouldUsePasteReplyForward(format: .plain,
                                                  accessibilityTrusted: false,
                                                  disabledByEnv: false))
    }

    func testShouldUsePasteReplyForward_disabledByEnv_false() {
        XCTAssertFalse(shouldUsePasteReplyForward(format: .plain,
                                                  accessibilityTrusted: true,
                                                  disabledByEnv: true))
    }

    func testReplyForwardPasteDisabledByEnv_detectsTruthyValues() {
        XCTAssertTrue(replyForwardPasteDisabledByEnv([replyForwardPasteDisableEnvKey: "1"]))
        XCTAssertTrue(replyForwardPasteDisabledByEnv([replyForwardPasteDisableEnvKey: "true"]))
        XCTAssertTrue(replyForwardPasteDisabledByEnv([replyForwardPasteDisableEnvKey: "YES"]))
        XCTAssertFalse(replyForwardPasteDisabledByEnv([replyForwardPasteDisableEnvKey: "0"]))
        XCTAssertFalse(replyForwardPasteDisabledByEnv([:]))
    }

    // MARK: - #237 mailtoIneligibilityReason (named reasons for the legacy fallback)

    func testIneligibilityReason_eligibleCall_returnsNil() {
        XCTAssertNil(mailtoIneligibilityReason(format: .plain,
                                               accessibilityTrusted: true,
                                               disabledByEnv: false,
                                               hasCustomSender: false,
                                               hasSubject: true))
    }

    func testIneligibilityReason_disabledByEnv_namesEnvKey() {
        let reason = mailtoIneligibilityReason(format: .plain,
                                               accessibilityTrusted: true,
                                               disabledByEnv: true,
                                               hasCustomSender: false,
                                               hasSubject: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains(mailtoComposeDisableEnvKey) == true,
                      "env reason must name the escape-hatch key: \(reason ?? "nil")")
    }

    func testIneligibilityReason_customSender_namesFromAddressAnd219() {
        let reason = mailtoIneligibilityReason(format: .plain,
                                               accessibilityTrusted: true,
                                               disabledByEnv: false,
                                               hasCustomSender: true,
                                               hasSubject: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("from_address") == true,
                      "custom-sender reason must name the parameter: \(reason ?? "nil")")
        XCTAssertTrue(reason?.contains("#219") == true,
                      "custom-sender reason must point at the sender-popup follow-up: \(reason ?? "nil")")
    }

    func testIneligibilityReason_emptySubject_namesSubject() {
        let reason = mailtoIneligibilityReason(format: .plain,
                                               accessibilityTrusted: true,
                                               disabledByEnv: false,
                                               hasCustomSender: false,
                                               hasSubject: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.lowercased().contains("subject") == true,
                      "empty-subject reason must mention the subject: \(reason ?? "nil")")
    }

    func testIneligibilityReason_nonPlainFormat_namesFormat() {
        for format in [BodyFormat.markdown, BodyFormat.html] {
            let reason = mailtoIneligibilityReason(format: format,
                                                   accessibilityTrusted: true,
                                                   disabledByEnv: false,
                                                   hasCustomSender: false,
                                                   hasSubject: true)
            XCTAssertNotNil(reason, "\(format) must be ineligible")
            XCTAssertTrue(reason?.contains(format.rawValue) == true,
                          "format reason must name the format: \(reason ?? "nil")")
        }
    }

    func testIneligibilityReason_noAccessibility_namesAccessibility() {
        let reason = mailtoIneligibilityReason(format: .plain,
                                               accessibilityTrusted: false,
                                               disabledByEnv: false,
                                               hasCustomSender: false,
                                               hasSubject: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Accessibility") == true,
                      "accessibility reason must name the missing grant: \(reason ?? "nil")")
    }

    func testIneligibilityReason_consistentWithShouldUseMailtoCompose() {
        // The boolean decision and the named reason must never disagree —
        // shouldUseMailtoCompose() is the routing source of truth (#175) and
        // mailtoIneligibilityReason() is its #237 disclosure companion.
        let bools = [false, true]
        for format in [BodyFormat.plain, .markdown, .html] {
            for ax in bools { for env in bools { for cs in bools { for subj in bools {
                let should = shouldUseMailtoCompose(format: format,
                                                    accessibilityTrusted: ax,
                                                    disabledByEnv: env,
                                                    hasCustomSender: cs,
                                                    hasSubject: subj)
                let reason = mailtoIneligibilityReason(format: format,
                                                       accessibilityTrusted: ax,
                                                       disabledByEnv: env,
                                                       hasCustomSender: cs,
                                                       hasSubject: subj)
                XCTAssertEqual(should, reason == nil,
                               "decision/reason mismatch for format=\(format) ax=\(ax) env=\(env) customSender=\(cs) hasSubject=\(subj)")
            }}}}
        }
    }

    // MARK: - #237 legacyPathDisclosure (result-string suffix)

    func testLegacyPathDisclosure_containsReasonAndWrapperWarning() {
        let suffix = legacyPathDisclosure(reason: "custom from_address test-reason")
        XCTAssertTrue(suffix.contains("legacy path"),
                      "disclosure must name the path: \(suffix)")
        XCTAssertTrue(suffix.contains("custom from_address test-reason"),
                      "disclosure must carry the named reason: \(suffix)")
        XCTAssertTrue(suffix.lowercased().contains("quoted"),
                      "disclosure must warn about quoted rendering on mobile clients: \(suffix)")
    }

    func testLegacyPathDisclosure_appendedResultKeepsSuccessPrefix() {
        // Callers may parse the historical success prefix — the disclosure is
        // append-only (#237 risk note).
        let result = "Draft created successfully" + legacyPathDisclosure(reason: "r")
        XCTAssertTrue(result.hasPrefix("Draft created successfully"), result)
        let sent = "Email sent successfully" + legacyPathDisclosure(reason: "r")
        XCTAssertTrue(sent.hasPrefix("Email sent successfully"), sent)
    }

    // MARK: - #229 pasteReplyForwardIneligibilityReason (named reasons, reply/forward family)

    func testPasteReplyIneligibilityReason_eligibleCall_returnsNil() {
        XCTAssertNil(pasteReplyForwardIneligibilityReason(format: .plain,
                                                          accessibilityTrusted: true,
                                                          disabledByEnv: false))
    }

    func testPasteReplyIneligibilityReason_disabledByEnv_namesEnvKey() {
        let reason = pasteReplyForwardIneligibilityReason(format: .plain,
                                                          accessibilityTrusted: true,
                                                          disabledByEnv: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains(replyForwardPasteDisableEnvKey) == true,
                      "env reason must name the escape-hatch key: \(reason ?? "nil")")
    }

    func testPasteReplyIneligibilityReason_nonPlainFormat_namesFormat() {
        for format in [BodyFormat.markdown, BodyFormat.html] {
            let reason = pasteReplyForwardIneligibilityReason(format: format,
                                                              accessibilityTrusted: true,
                                                              disabledByEnv: false)
            XCTAssertNotNil(reason, "\(format) must be ineligible")
            XCTAssertTrue(reason?.contains(format.rawValue) == true,
                          "format reason must name the format: \(reason ?? "nil")")
        }
    }

    func testPasteReplyIneligibilityReason_noAccessibility_namesAccessibility() {
        let reason = pasteReplyForwardIneligibilityReason(format: .plain,
                                                          accessibilityTrusted: false,
                                                          disabledByEnv: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Accessibility") == true,
                      "accessibility reason must name the missing grant: \(reason ?? "nil")")
    }

    func testPasteReplyIneligibilityReason_consistentWithShouldUsePasteReplyForward() {
        // Same never-disagree contract as the #237 compose pair:
        // shouldUsePasteReplyForward() routes (#218), the reason names why not.
        let bools = [false, true]
        for format in [BodyFormat.plain, .markdown, .html] {
            for ax in bools { for env in bools {
                let should = shouldUsePasteReplyForward(format: format,
                                                        accessibilityTrusted: ax,
                                                        disabledByEnv: env)
                let reason = pasteReplyForwardIneligibilityReason(format: format,
                                                                  accessibilityTrusted: ax,
                                                                  disabledByEnv: env)
                XCTAssertEqual(should, reason == nil,
                               "decision/reason mismatch for format=\(format) ax=\(ax) env=\(env)")
            }}
        }
    }

    // MARK: - #229 legacyReplyPathDisclosure (result-string suffix, reply/forward family)

    func testLegacyReplyPathDisclosure_scopesWarningToNewBodyAndCarriesReason() {
        let suffix = legacyReplyPathDisclosure(reason: "format 'markdown' test-reason")
        XCTAssertTrue(suffix.contains("legacy path"),
                      "disclosure must name the path: \(suffix)")
        XCTAssertTrue(suffix.contains("format 'markdown' test-reason"),
                      "disclosure must carry the named reason: \(suffix)")
        XCTAssertTrue(suffix.contains("new body"),
                      "disclosure must scope the warning to the NEW body — the quoted original's cite blockquote is legitimate (#218): \(suffix)")
        XCTAssertTrue(suffix.lowercased().contains("quoted"),
                      "disclosure must warn about quoted rendering on mobile clients: \(suffix)")
    }

    func testClampedErrorEcho_foldsAllNewlineFlavorsAndControls_andCapsLength() {
        // #229 verify finding: \n-only folding left \r / CRLF / U+2028 / U+2029 /
        // control chars able to break the one-bounded-line contract.
        let messy = "line1\r\nline2\rline3\u{2028}line4\u{2029}line5\tline6\nend"
        let out = clampedErrorEcho(messy)
        for bad in ["\n", "\r", "\u{2028}", "\u{2029}", "\t"] {
            XCTAssertFalse(out.contains(bad), "separator/control must be folded: \(out.debugDescription)")
        }
        XCTAssertTrue(out.contains("line1  line2"),
                      "CRLF folds to two spaces (one per scalar) — content preserved: \(out.debugDescription)")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(clampedErrorEcho(long).count, 200, "default cap is 200 chars")
    }

    func testLegacyReplyPathDisclosure_appendedKeepsSuccessPrefixes() {
        // Legacy reply/forward success strings (ComposeScriptBuilder) must stay
        // prefix-stable for prefix-parsing callers — append-only, like #237.
        for prefix in ["Reply sent successfully", "Reply saved as draft", "Email forwarded successfully"] {
            let result = prefix + legacyReplyPathDisclosure(reason: "r")
            XCTAssertTrue(result.hasPrefix(prefix), result)
        }
    }
}

// MARK: - #220 non-ASCII attachment paths route to the legacy (native-attach) path

extension MailtoComposeTests {

    func testAttachmentPathsGuiSafe() {
        XCTAssertTrue(attachmentPathsGuiSafe(nil))
        XCTAssertTrue(attachmentPathsGuiSafe([]))
        XCTAssertTrue(attachmentPathsGuiSafe(["/Users/che/report.pdf", "/tmp/data.csv"]))
        XCTAssertFalse(attachmentPathsGuiSafe(["/Users/che/「議程」.pdf"]),
                       "fullwidth brackets hang the go-to-folder sheet (#220)")
        XCTAssertFalse(attachmentPathsGuiSafe(["/Users/che/會議通知.pdf"]))
        XCTAssertFalse(attachmentPathsGuiSafe(["/ok/a.pdf", "/bad/附件.pdf"]),
                       "one unsafe path taints the batch — the GUI loop attaches all of them")
    }

    func testIneligibility_nonAsciiAttachmentPath_namedReason() {
        let reason = mailtoIneligibilityReason(
            format: .plain, accessibilityTrusted: true, disabledByEnv: false,
            hasCustomSender: false, hasSubject: true,
            attachmentsGuiSafe: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("#220"), "reason must cite the hang issue: \(reason!)")
        XCTAssertTrue(reason!.contains("non-ASCII"), reason!)
    }

    func testIneligibility_asciiAttachments_stillEligible() {
        XCTAssertNil(mailtoIneligibilityReason(
            format: .plain, accessibilityTrusted: true, disabledByEnv: false,
            hasCustomSender: false, hasSubject: true,
            attachmentsGuiSafe: true))
    }
}


// MARK: - #220 wiring lock

extension MailtoComposeTests {

    func testWiring_allFourProbeSitesThreadAttachments() throws {
        // Reverting the `attachments:` argument at any one probe site keeps
        // the suite green otherwise (the seam override short-circuits before
        // the real probe) — pin the wiring by source scan, the repo's
        // idiomatic lock for behaviorally-unreachable invariants (#220).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let attachCount = source.components(separatedBy: "attachments: attachments,").count - 1
        XCTAssertEqual(attachCount, 4,
                       "all four compose-family probe sites must thread attachments into "
                       + "mailtoIneligibilityReasonForCall (#220); found \(attachCount)")
        // #251: the same four sites must also thread the recipient lists so the
        // display-name dimension is probed.
        let recipCount = source.components(
            separatedBy: "recipients: to + (cc ?? []) + (bcc ?? []))").count - 1
        XCTAssertEqual(recipCount, 4,
                       "all four probe sites must thread recipients (#251); found \(recipCount)")
    }
}
