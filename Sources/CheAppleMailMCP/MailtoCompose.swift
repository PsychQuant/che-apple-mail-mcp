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
/// #220 — true iff every attachment path is pure ASCII. The mailto path
/// attaches via the GUI go-to-folder sheet (⇧⌘G + paste), which hangs
/// deterministically on CJK/fullwidth paths (live repro, v2.17.0) — the
/// panel-closed proxy can't detect a sheet that never accepts its input.
/// ASCII-only paths are the known-good set; anything else routes to the
/// legacy path, whose native `POSIX file` attachment handles any path.
func attachmentPathsGuiSafe(_ paths: [String]?) -> Bool {
    guard let paths, !paths.isEmpty else { return true }
    return paths.allSatisfy { $0.allSatisfy(\.isASCII) }
}


/// #251 — parse an RFC 5322 mailbox form `Name <email>` (or `"Name" <email>`)
/// into (name, address). A bare address returns (nil, input); a bare-angle
/// form `<email>` normalizes to the inner address (verify round). An UNQUOTED
/// name containing `<`/`>` is malformed — RFC 5322 makes them specials,
/// forbidden in unquoted atoms — and returns (nil, input) so the boundary
/// validation rejects it on the whole string (verify REQUIRED: a multi-angle
/// input like `A <a@x> <b@y>` must fail loudly, never silently reinterpret
/// as a send to the LAST address). Quoted names may contain specials.
/// Whitespace-tolerant.
func parseRecipient(_ raw: String) -> (name: String?, address: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasSuffix(">"), let lt = trimmed.lastIndex(of: "<") else {
        return (nil, trimmed)
    }
    let addrStart = trimmed.index(after: lt)
    let addrEnd = trimmed.index(before: trimmed.endIndex)
    let address = String(trimmed[addrStart..<addrEnd]).trimmingCharacters(in: .whitespaces)
    guard !address.isEmpty else { return (nil, trimmed) }
    var name = String(trimmed[..<lt]).trimmingCharacters(in: .whitespaces)
    if name.isEmpty {
        // Bare-angle `<a@b.c>` — an addr-spec in angles; normalize.
        return (nil, address)
    }
    let wasQuoted = name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2
    if wasQuoted {
        // #266: decode RFC 5322 quoted-pairs inside the quoted display name so
        // the native recipient name carries the intended value (`\"` → `"`,
        // `\\` → `\`), not the backslash-escaped source form. Any `\x` becomes
        // `x`; an unbalanced trailing backslash is kept literally.
        name = unescapeQuotedPairs(String(name.dropFirst().dropLast()))
    } else if name.contains("<") || name.contains(">") {
        // Unquoted angles in the name = malformed (extra/unmatched pairs) —
        // fail loudly via whole-string validation, never reinterpret.
        return (nil, trimmed)
    }
    guard !name.isEmpty else { return (nil, trimmed) }
    return (name, address)
}

/// #266 — decode RFC 5322 quoted-pairs (`\x` → `x`) in a quoted-string body
/// (outer quotes already stripped). A backslash escapes the next character; a
/// trailing lone backslash is kept literally. Single pass.
func unescapeQuotedPairs(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var escaped = false
    for ch in s {
        if escaped {
            out.append(ch)
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else {
            out.append(ch)
        }
    }
    if escaped { out.append("\\") }
    return out
}

/// #270 — true iff the string contains a `<` or `>` that is NOT inside a
/// well-formed RFC 5322 quoted string in a position where one may appear.
/// Quote state honors quoted-pairs (`\"` stays inside the quoted string —
/// same escape semantics as `unescapeQuotedPairs`). Two verify-round (R1,
/// Codex) tightenings keep the exemption honest:
///   - An UNTERMINATED quote is not a quoted-string at all (RFC 5322), so
///     angles seen inside one count as unquoted at EOF (`"a<b@x`, and the
///     #265-regression shape `"a<b>@x`, are both rejected).
///   - A quoted-string cannot appear in the DOMAIN — after the first
///     unquoted `@`, a `"` is a literal, so `a@"<x>"` counts its angles.
/// Used by the boundary validator to reject stray angles whether paired
/// (`x <a@b> <c@d>`, #265) or unpaired (`<a@x` / `a@x>`, #270) without
/// mis-rejecting legal quoted local-parts (`"a<b"@x`). Single pass.
///
/// Iterates unicodeScalars, NOT Characters (#280 verify, Codex): a `>`
/// followed by a combining scalar (e.g. U+FE0F variation selector) fuses
/// into one extended grapheme cluster under Character iteration, so the
/// cluster compares unequal to ">" and the stray angle slips the scan.
/// Every structural character here (`"` `\` `@` `<` `>`) is a single ASCII
/// scalar, so scalar-level comparison is strictly more precise.
func containsUnquotedAngle(_ s: String) -> Bool {
    var inQuote = false
    var escaped = false
    var angleInOpenQuote = false
    var seenUnquotedAt = false
    for ch in s.unicodeScalars {
        if inQuote {
            if escaped {
                // R2 (Codex): an escaped angle is still an angle character —
                // record it, or an unterminated quote holding `\<` / `\>`
                // would bypass the EOF check below (re-opening the #265
                // paired-shape regression via `"a\<b\>@x`). A properly
                // closed quote still resets the record, so the legal
                // `"a\<b\>"@x` stays exempt.
                if ch == "<" || ch == ">" { angleInOpenQuote = true }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inQuote = false
                angleInOpenQuote = false
            } else if ch == "<" || ch == ">" {
                angleInOpenQuote = true
            }
        } else if ch == "\"" {
            // Quotes may only open a quoted-string in the local part; after
            // an unquoted `@` they are literal characters.
            if !seenUnquotedAt { inQuote = true }
        } else if ch == "@" {
            seenUnquotedAt = true
        } else if ch == "<" || ch == ">" {
            return true
        }
    }
    // EOF with an open quote: no quoted-string was formed — any angle seen
    // inside it was never actually protected.
    return inQuote && angleInOpenQuote
}

/// #251 — true iff any recipient in the given lists carries a display name.
func anyRecipientHasDisplayName(_ recipients: [String]?) -> Bool {
    guard let recipients else { return false }
    return recipients.contains { parseRecipient($0).name != nil }
}

func mailtoIneligibilityReason(
    format: BodyFormat,
    accessibilityTrusted: Bool,
    disabledByEnv: Bool,
    hasCustomSender: Bool,
    hasSubject: Bool,
    attachmentsGuiSafe: Bool = true,
    recipientsAddrSpecOnly: Bool = true
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
    if !attachmentsGuiSafe {
        return "attachment path contains non-ASCII characters — the GUI go-to-folder "
            + "attach flow hangs there (#220); the legacy path attaches natively instead"
    }
    if !recipientsAddrSpecOnly {
        return "display-name recipients (Name <email>) — the mailto URL carries "
            + "addr-spec only (RFC 6068); the legacy path sets recipient names natively (#251)"
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
        + "Accessibility granted + \(mailtoComposeDisableEnvKey) unset + "
        + "ASCII-only attachment paths (#220) + bare-address recipients (#251) "
        + "(#175; custom-sender clean path pending #219)]"
}

/// #241 — the #237/#229 clean-path-or-disclosed-legacy control flow, extracted
/// from the four `MailController` compose-family sites (compose_email /
/// create_draft / reply_email / forward_email-with-body) behind injectable
/// closures so the WIRING itself has a runnable regression lock (the pure
/// helpers were pinned, but deleting the inline wiring kept the suite green —
/// the #237 silent-regression pattern one level up).
///
/// Contract (byte-identical to the previous inline wiring):
/// - `ineligibilityReason == nil` → try `cleanPath`; its success returns
///   verbatim (NO suffix). Its failure fires `warnTriedAndFailed` once, then
///   the legacy result is suffixed with `disclosure(fallbackReason(error))`.
/// - `ineligibilityReason != nil` → `cleanPath` is never attempted;
///   `warnIneligible` fires once; the legacy result is suffixed with
///   `disclosure(reason)`.
/// - `legacyPath` errors always propagate.

/// #242 — true iff `error` carries the POSTDISPATCH sentinel that
/// `buildMailtoComposeScript` (send:true) attaches to any error thrown at or
/// after the send-keystroke dispatch. Such errors mean the send state is
/// UNKNOWN (the mail may already be on the wire) — the caller must NOT fall
/// back to a legacy re-send.
func isPostDispatchError(_ error: Error) -> Bool {
    if case MailError.scriptFailed(let message, _) = error {
        // Prefix-only, symmetric with the AppleScript `does not start with`
        // cleanup check — a mid-string token (user-controlled content echoed
        // into a pre-dispatch error) must not classify (#242 verify).
        return message.hasPrefix("POSTDISPATCH:")
    }
    return false
}

/// #242 — `shouldFallback` gates the tried-and-failed branch: when it returns
/// false (a POSTDISPATCH send-stage error), the router rethrows
/// `mapNoFallbackError(error)` immediately — no fallback warn, no legacy run,
/// no disclosure. Defaults preserve the pre-#242 behavior for every other site.
func routeWrapperFreeCompose(
    ineligibilityReason: String?,
    cleanPath: () throws -> String,
    legacyPath: () throws -> String,
    disclosure: (String) -> String,
    warnIneligible: (String) -> Void,
    warnTriedAndFailed: (Error) -> Void,
    fallbackReason: (Error) -> String,
    shouldFallback: (Error) -> Bool = { _ in true },
    mapNoFallbackError: (Error) -> Error = { $0 }
) throws -> String {
    var legacyReason = ineligibilityReason
    if legacyReason == nil {
        do {
            return try cleanPath()
        } catch {
            guard shouldFallback(error) else {
                throw mapNoFallbackError(error)
            }
            warnTriedAndFailed(error)
            legacyReason = fallbackReason(error)
            // fall through to legacy injection
        }
    } else {
        warnIneligible(legacyReason!)
    }
    let result = try legacyPath()
    return result + disclosure(legacyReason ?? "unknown")
}

/// #239 — the `require_wrapper_free: true` refusal message: names the
/// ineligibility reason and every actionable alternative, so the caller can
/// fix the call instead of receiving a silently wrapped draft.
func requireWrapperFreeRefusal(reason: String) -> String {
    return "require_wrapper_free is set but the wrapper-free mailto path is not available — "
        + "reason: \(reason). No draft was created and nothing was sent. Alternatives: "
        + "omit from_address (compose from the default account and switch sender manually in "
        + "the compose window — clean custom-sender path is pending #219); use format 'plain'; "
        + "provide a non-empty subject; grant Accessibility (check_accessibility); "
        + "use ASCII-only attachment paths (#220); use bare addresses without display names (#251); "
        + "unset \(mailtoComposeDisableEnvKey). Or drop require_wrapper_free to accept the "
        + "legacy path (body wrapped in <blockquote type=\"cite\"> on some mobile clients)."
}

/// #242/#239 — the canonical unknown-send-state error for a compose-family
/// send whose dispatch was already attempted: names the hazard, directs the
/// caller to check Sent/Outbox, and explicitly forbids a retry (an
/// auto-retrying LLM caller would otherwise re-send — the exact duplicate
/// hazard the sentinel exists to prevent). Shared by the default path's
/// router hook and the #239 strict branch.
func unknownSendStateError(_ error: Error) -> MailError {
    return MailError.scriptFailed(
        message: "the send keystroke was already dispatched but the GUI step failed "
            + "afterwards — the send state is UNKNOWN and the mail may already be on "
            + "the wire. NOT retrying via the legacy path (that could send a duplicate). "
            + "Check Mail's Sent mailbox / Outbox before re-sending. The compose window "
            + "(if still open) was left untouched for inspection. Original error: "
            + clampedErrorEcho(error.localizedDescription),
        code: -1)
}
