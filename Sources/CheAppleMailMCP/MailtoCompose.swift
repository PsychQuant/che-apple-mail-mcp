import Foundation

// MARK: - #175 mailto-based clean-body compose
//
// Mail.app wraps ANY AppleScript-injected outgoing-message body
// (`content:` / `set content` / `set html content`) in its
// `Apple-Mail-URLShareWrapperClass` › `blockquote type="cite"` "inserted /
// shared content" path at MIME-serialization time — so recipients (esp. mobile
// clients honoring `cite`) see the user's own new text rendered as a quotation.
// The wrapper cannot be stripped after the fact (reading the live outgoing
// message's `html content` → AppleScript -1723; re-setting clean HTML → re-wraps;
// editing the saved `.emlx` → overwritten by Mail on send). The ONLY wrapper-free
// paths are Mail's native editor: typing, clipboard paste, and the `mailto:`
// hand-off. `mailto:` is the robust one (it populates the body itself, so there
// is no fragile "focus the body field" step), at the cost of being plain-text
// only and needing a GUI keystroke (Accessibility TCC) to save/send.
//
// This file holds the PURE, unit-testable pieces: the URL builder and the
// "use mailto vs fall back to legacy injection" decision. The GUI orchestration
// (open window → sender popup → attach files → Cmd+S / Cmd+Shift+D) lives in
// MailController and is gated/live-tested.

/// RFC 3986 unreserved characters — everything else is percent-encoded. This is
/// deliberately conservative (matches Python's `urllib.parse.quote` default):
/// `@`, spaces, newlines, `&`, `=`, `?`, CJK, etc. all become `%XX`, so no body
/// or subject content can leak into the URL's structural delimiters.
///
/// Spelled out as an explicit ASCII set rather than `CharacterSet.alphanumerics`.
/// In practice both encode CJK/accented input identically (`addingPercentEncoding`
/// operates on UTF-8 bytes), so the old set was NOT buggy — but `.alphanumerics`
/// is Unicode-inclusive by definition, making the percent-encode contract depend
/// on a Foundation implementation detail. The explicit ASCII set pins the
/// contract the tests assert, independent of that detail (#175 verify, Codex).
private let mailtoUnreserved: CharacterSet =
    CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// Upper bound on the encoded `mailto:` URL length. Beyond this, the native
/// compose path risks silent body truncation (URL parsers / Mail), so the caller
/// falls back to the legacy injection path (which has no length limit). 8000 is
/// well under typical OS URL ceilings while comfortably fitting ordinary mail.
let maxMailtoURLLength = 8000

/// Percent-encode a single mailto component (recipient / subject / body).
func mailtoEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: mailtoUnreserved) ?? ""
}

/// Build a percent-encoded `mailto:` URL that Mail's native compose pipeline
/// renders WITHOUT the `blockquote type="cite"` wrapper (#175).
///
/// Recipients go in the path (comma-joined); cc/bcc/subject/body are query
/// params. Empty/nil cc/bcc are omitted. `body` is plain text — newlines become
/// `%0A` (Mail renders them as `<br>`).
func buildMailtoURL(
    to: [String],
    subject: String,
    body: String,
    cc: [String]? = nil,
    bcc: [String]? = nil
) -> String {
    let toPart = to.map(mailtoEncode).joined(separator: ",")
    var query: [String] = []
    if let cc = cc, !cc.isEmpty {
        query.append("cc=" + cc.map(mailtoEncode).joined(separator: ","))
    }
    if let bcc = bcc, !bcc.isEmpty {
        query.append("bcc=" + bcc.map(mailtoEncode).joined(separator: ","))
    }
    query.append("subject=" + mailtoEncode(subject))
    query.append("body=" + mailtoEncode(body))
    var url = "mailto:" + toPart
    if !query.isEmpty { url += "?" + query.joined(separator: "&") }
    return url
}

/// Environment escape hatch: set `CHE_MAIL_DISABLE_MAILTO_COMPOSE=1` to force the
/// legacy AppleScript injection path (wrapped body) — for users running compose
/// in heavy/unattended automation where a briefly-visible compose window and GUI
/// keystrokes are unacceptable. Absence/`0`/empty → mailto path enabled.
let mailtoComposeDisableEnvKey = "CHE_MAIL_DISABLE_MAILTO_COMPOSE"

func mailtoComposeDisabledByEnv(
    _ env: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard let raw = env[mailtoComposeDisableEnvKey] else { return false }
    return raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
}

/// Decide whether the wrapper-free mailto path is usable for this compose call.
///
/// Returns `false` (→ caller falls back to the legacy AppleScript injection path,
/// which produces the wrapper but always works) when:
/// - `format` is `.markdown` / `.html` — mailto carries plain text only;
/// - Accessibility (`AXIsProcessTrusted`) is not granted — the GUI keystrokes
///   for save/send/attach/sender would silently fail;
/// - the env escape hatch disabled it.
///
/// Attachments do NOT disqualify the mailto path — they are handled by GUI
/// automation (File ▸ Attach, driven by the locale-independent ⇧⌘A shortcut).
///
/// A custom `from_address` (#131) DOES disqualify it: `mailto:` always composes
/// from the default account, and selecting a different account would require
/// driving the sender popup — which can't be safely verified yet and a wrong
/// pick would send from the wrong account. Until a verified sender-popup lands
/// (follow-up issue), custom-sender compose falls back to the legacy `set sender`
/// path (correct sender, but the body gets wrapped).
///
/// An EMPTY subject also disqualifies it (#175 verify): the GUI dispatch guard
/// identifies the compose window by its title (= subject) to guarantee ⌘S/⇧⌘D
/// fire into OUR window and not one the user opened during the delay. With no
/// title there is no reliable identity check, so empty-subject compose falls
/// back to the legacy path.
func shouldUseMailtoCompose(
    format: BodyFormat,
    accessibilityTrusted: Bool,
    disabledByEnv: Bool,
    hasCustomSender: Bool,
    hasSubject: Bool
) -> Bool {
    // #237: thin wrapper over the reason-returning variant so the routing
    // decision and the disclosed reason can never disagree.
    return mailtoIneligibilityReason(
        format: format,
        accessibilityTrusted: accessibilityTrusted,
        disabledByEnv: disabledByEnv,
        hasCustomSender: hasCustomSender,
        hasSubject: hasSubject
    ) == nil
}

// MARK: - #218 clean reply/forward (native-verb + paste)
//
// reply_email / forward_email have the SAME wrapper bug as #175 compose: the
// new reply/forward text, injected via `set content` / `set html content`, is
// wrapped in `Apple-Mail-URLShareWrapperClass` / `blockquote type="cite"` so
// mobile recipients see the user's OWN new text as a quotation. The #175 mailto
// fix does NOT transfer — `mailto:` always opens a *fresh* compose and can't
// thread a reply or carry the quoted original.
//
// The clean path drives Mail's NATIVE `reply` / `forward` verb (Mail builds the
// quoted original itself — legitimately in a `blockquote type="cite"` — and sets
// the In-Reply-To / References threading headers), then pastes ONLY the new body
// at the cursor via System Events. The native quote stays correct; only the new
// text avoids the wrapper. Like #175 it is plain-only (clipboard carries plain)
// and needs Accessibility (the GUI paste/dispatch keystrokes).

/// Environment escape hatch: set `CHE_MAIL_DISABLE_PASTE_REPLY=1` to force the
/// legacy AppleScript injection path (wrapped new body) for reply/forward — for
/// users running in heavy/unattended automation where a briefly-visible reply
/// window and GUI keystrokes are unacceptable. Independent of the compose
/// (`CHE_MAIL_DISABLE_MAILTO_COMPOSE`) hatch so the two GUI paths can be toggled
/// separately. Absence/`0`/empty → clean paste path enabled.
let replyForwardPasteDisableEnvKey = "CHE_MAIL_DISABLE_PASTE_REPLY"

func replyForwardPasteDisabledByEnv(
    _ env: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard let raw = env[replyForwardPasteDisableEnvKey] else { return false }
    return raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
}

/// Decide whether the wrapper-free native-verb + paste path is usable for this
/// reply/forward. Returns `false` (→ caller falls back to the legacy AppleScript
/// injection path, which wraps the new body but always works) when:
/// - `format` is `.markdown` / `.html` — the clipboard paste carries plain text
///   only (the legacy path renders rich bodies, at the cost of the wrapper);
/// - Accessibility (`AXIsProcessTrusted`) is not granted — the GUI paste/dispatch
///   keystrokes would silently fail;
/// - the env escape hatch disabled it.
///
/// Unlike `shouldUseMailtoCompose`, there is no compile-time subject/sender gate
/// (a reply has no subject param). The window is identified by **id-delta** in the
/// Mail model, and `buildReplyForwardPasteScript` gates each keystroke phase on a
/// RUNTIME front-window-id check (`id of front window` ∈ the id-delta set) — so a
/// stolen focus degrades to the legacy fallback. The mailto path's title bridge is
/// NOT reused: reply/forward compose windows expose an empty `name`, so title
/// matching is unusable here (#218 verify, live-verified).
func shouldUsePasteReplyForward(
    format: BodyFormat,
    accessibilityTrusted: Bool,
    disabledByEnv: Bool
) -> Bool {
    // #229: thin wrapper over the reason-returning variant so the routing
    // decision and the disclosed reason can never disagree (mirrors #237's
    // shouldUseMailtoCompose / mailtoIneligibilityReason pair).
    return pasteReplyForwardIneligibilityReason(
        format: format,
        accessibilityTrusted: accessibilityTrusted,
        disabledByEnv: disabledByEnv
    ) == nil
}

// MARK: - #229 legacy-path disclosure (reply/forward family)

/// #229 — why this reply/forward call cannot use the clean native-verb + paste
/// path (#218). `nil` = eligible. Check order mirrors
/// `shouldUsePasteReplyForward`'s short-circuit so the two can never disagree
/// (guarded by the consistency matrix test).
///
/// Motivation: the #218 clean path degrades to the legacy injection (which
/// wraps the NEW body in `<blockquote type="cite">`) for markdown/html, without
/// Accessibility, or via the env hatch — previously with no result-level
/// disclosure at all (ineligible calls were fully silent). Same failure shape
/// as compose's #237; this names the reason for the reply/forward family.
func pasteReplyForwardIneligibilityReason(
    format: BodyFormat,
    accessibilityTrusted: Bool,
    disabledByEnv: Bool
) -> String? {
    if disabledByEnv {
        return "paste reply/forward disabled via \(replyForwardPasteDisableEnvKey)"
    }
    guard format == .plain else {
        return "format '\(format.rawValue)' — the clipboard paste carries plain text only"
    }
    if !accessibilityTrusted {
        return "Accessibility (AXIsProcessTrusted) not granted — the GUI paste/dispatch "
            + "keystrokes would silently fail"
    }
    return nil
}

/// #229 — fold every newline flavor (\n, \r, CRLF, U+2028, U+2029, NEL) and
/// control character to a single space and cap the length, so an echoed GUI
/// error stays one bounded line inside a result-string disclosure.
func clampedErrorEcho(_ text: String, limit: Int = 200) -> String {
    let separators = CharacterSet.newlines.union(.controlCharacters)
    let folded = text.unicodeScalars
        .map { separators.contains($0) ? " " : String($0) }
        .joined()
    return String(folded.prefix(limit))
}

/// #229 — suffix appended to legacy-path reply/forward result strings so the
/// MCP caller learns the NEW body will render as a quote on some mobile
/// clients. Scoped to the new body on purpose: the quoted ORIGINAL's cite
/// blockquote is the legitimate structure Mail builds for a reply (#218).
/// Append-only: the historical `Reply sent successfully` / `Reply saved as
/// draft` / `Email forwarded successfully` prefixes stay intact.
func legacyReplyPathDisclosure(reason: String) -> String {
    return " [legacy path — the new body is wrapped in <blockquote type=\"cite\">, renders as "
        + "quoted text on some mobile clients (the quoted original's cite block is normal). "
        + "Reason: \(reason). Clean-path eligibility: plain format + Accessibility granted + "
        + "\(replyForwardPasteDisableEnvKey) unset (#218)]"
}

// MARK: - #237 legacy-path disclosure

/// #237 — why this compose call cannot use the wrapper-free mailto path.
/// `nil` = eligible. Check order mirrors `shouldUseMailtoCompose`'s
/// short-circuit so the two can never disagree (guarded by the
/// `consistentWithShouldUseMailtoCompose` matrix test).
///
/// Motivation (#237 RCA): every 2026-07-09 `create_draft` carried a custom
/// `from_address`, silently routing to the legacy injection path whose body
/// Mail wraps in `<blockquote type="cite">` at MIME-serialization time. The
/// ineligibility itself is by design (#131/#175) — the bug was that nothing
/// disclosed it. This function names the reason so the result string, the
/// stderr warn, and the tool description can all surface the same fact.
func mailtoIneligibilityReason(
    format: BodyFormat,
    accessibilityTrusted: Bool,
    disabledByEnv: Bool,
    hasCustomSender: Bool,
    hasSubject: Bool
) -> String? {
    if disabledByEnv {
        return "mailto compose disabled via \(mailtoComposeDisableEnvKey)"
    }
    if hasCustomSender {
        return "custom from_address — mailto: composes from the default account only; "
            + "a verified sender-popup is pending #219"
    }
    if !hasSubject {
        return "empty subject — the GUI dispatch guard identifies our compose window "
            + "by its title (= subject)"
    }
    guard format == .plain else {
        return "format '\(format.rawValue)' — the mailto: URL carries plain text only"
    }
    if !accessibilityTrusted {
        return "Accessibility (AXIsProcessTrusted) not granted — GUI keystrokes for "
            + "save/send/attach would silently fail"
    }
    return nil
}

/// #237 — suffix appended to legacy-path result strings so the MCP caller
/// (not just stderr) learns the body will render as a quote on some mobile
/// clients. Append-only: the historical `Draft created successfully` /
/// `Email sent successfully` prefixes stay intact for prefix-parsing callers.
func legacyPathDisclosure(reason: String) -> String {
    return " [legacy path — body wrapped in <blockquote type=\"cite\">, renders as "
        + "quoted text on some mobile clients. Reason: \(reason). Wrapper-free "
        + "eligibility: plain format + non-empty subject + default sender + "
        + "Accessibility granted + \(mailtoComposeDisableEnvKey) unset "
        + "(#175; custom-sender clean path pending #219)]"
}
