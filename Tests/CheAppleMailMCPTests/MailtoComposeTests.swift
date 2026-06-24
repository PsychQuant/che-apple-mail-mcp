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

    func testShouldUseMailto_plain_trusted_enabled_noCustomSender_true() {
        XCTAssertTrue(shouldUseMailtoCompose(format: .plain,
                                             accessibilityTrusted: true,
                                             disabledByEnv: false,
                                             hasCustomSender: false))
    }

    func testShouldUseMailto_htmlFormat_false() {
        // mailto is plain-only — markdown/html MUST use the legacy path.
        XCTAssertFalse(shouldUseMailtoCompose(format: .html,
                                              accessibilityTrusted: true,
                                              disabledByEnv: false,
                                              hasCustomSender: false))
        XCTAssertFalse(shouldUseMailtoCompose(format: .markdown,
                                              accessibilityTrusted: true,
                                              disabledByEnv: false,
                                              hasCustomSender: false))
    }

    func testShouldUseMailto_noAccessibility_false() {
        XCTAssertFalse(shouldUseMailtoCompose(format: .plain,
                                              accessibilityTrusted: false,
                                              disabledByEnv: false,
                                              hasCustomSender: false))
    }

    func testShouldUseMailto_disabledByEnv_false() {
        XCTAssertFalse(shouldUseMailtoCompose(format: .plain,
                                              accessibilityTrusted: true,
                                              disabledByEnv: true,
                                              hasCustomSender: false))
    }

    func testShouldUseMailto_customSender_false() {
        // mailto can't pick a non-default account → legacy path handles sender.
        XCTAssertFalse(shouldUseMailtoCompose(format: .plain,
                                              accessibilityTrusted: true,
                                              disabledByEnv: false,
                                              hasCustomSender: true))
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

    func testMailtoScript_send_usesSendShortcutAndWindowGuard() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B")
        let s = buildMailtoComposeScript(url: url, subject: "S", attachments: [], send: true)
        // dispatch = ⇧⌘D (send), not ⌘S
        XCTAssertTrue(s.contains("keystroke \"d\" using {command down, shift down}"), s)
        XCTAssertFalse(s.contains("keystroke \"s\" using command down"), s)
        XCTAssertTrue(s.contains("Email sent successfully (mailto path)"))
        // never dispatch into the void: window-count delta guard present
        XCTAssertTrue(s.contains("count of windows"))
        XCTAssertTrue(s.contains(url))
    }

    func testMailtoScript_draft_usesSaveShortcut() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B")
        let s = buildMailtoComposeScript(url: url, subject: "S", attachments: [], send: false)
        XCTAssertTrue(s.contains("keystroke \"s\" using command down"), s)
        XCTAssertFalse(s.contains("keystroke \"d\" using {command down, shift down}"), s)
        XCTAssertTrue(s.contains("Draft created successfully (mailto path)"))
    }

    func testMailtoScript_noAttachments_omitsAttachAndClipboard() {
        let s = buildMailtoComposeScript(url: "mailto:a%40b.c", subject: "S",
                                         attachments: [], send: false)
        // ⇧⌘A is the Attach shortcut — must be absent with no attachments
        XCTAssertFalse(s.contains("keystroke \"a\" using {command down, shift down}"), s)
        XCTAssertFalse(s.contains("the clipboard"), s)
    }

    func testMailtoScript_attachments_oneAttachCyclePerFile_localeIndependent() {
        let s = buildMailtoComposeScript(url: "mailto:a%40b.c", subject: "S",
                                         attachments: ["/tmp/a.pdf", "/tmp/b.txt"], send: false)
        // one File▸Attach (⇧⌘A) per attachment
        let attachCount = s.components(separatedBy: "keystroke \"a\" using {command down, shift down}").count - 1
        XCTAssertEqual(attachCount, 2, "expected one ⇧⌘A per attachment: \(s)")
        // go-to-folder (⇧⌘G) used for path entry; both paths present; clipboard save/restore
        XCTAssertTrue(s.contains("keystroke \"g\" using {command down, shift down}"))
        XCTAssertTrue(s.contains("/tmp/a.pdf") && s.contains("/tmp/b.txt"))
        XCTAssertTrue(s.contains("set _savedClip") && s.contains("set the clipboard to _savedClip"))
        // locale-independence: no hardcoded localized menu names (the #174 trap)
        XCTAssertFalse(s.contains("附加檔案"))
        XCTAssertFalse(s.contains("Attach"))
    }
}
