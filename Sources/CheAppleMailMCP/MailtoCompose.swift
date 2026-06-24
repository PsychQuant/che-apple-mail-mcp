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
    if disabledByEnv { return false }
    if hasCustomSender { return false }
    if !hasSubject { return false }
    guard format == .plain else { return false }
    return accessibilityTrusted
}
