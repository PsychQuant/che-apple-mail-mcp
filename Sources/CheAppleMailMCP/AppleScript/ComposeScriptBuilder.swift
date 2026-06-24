import Foundation

func appleScriptEscape(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r\n", with: "\" & return & \"")
        .replacingOccurrences(of: "\n", with: "\" & return & \"")
        .replacingOccurrences(of: "\r", with: "\" & return & \"")
        .replacingOccurrences(of: "\t", with: "\" & tab & \"")
}

// Issue #39 / #61: helper-owns-indent contract.
// `attachmentFragment` and `recipientFragment` emit lines with their own
// 4-space indent baked in. Callers MUST prefix with bare "\n" (newline only,
// no extra spaces) — the helper output already has the indent. Adding
// extra prefix at call sites breaks visual alignment between first line
// (caller-prefix + helper-indent = double-indented) and subsequent lines
// (separator-only + helper-indent = single-indented), regressing #39's
// single-source-of-truth promise.
//
// Issue #60: Mail.app's AppleScript attachment pipeline is asynchronous.
// Two failure modes when emitting consecutive `make new attachment` calls
// without pacing: (1) `at after the last paragraph` in the next call
// resolves to the same anchor as the previous one because the previous
// insert hasn't materialized yet — Mail.app's collision behavior drops
// all but one; (2) `save` / `send` commits before in-flight attachment
// binds drain. For N >= 2 we interleave `delay 0.3` between attachments
// (gives anchor materialization time) and append `delay 0.5` trailing
// (ensures pipeline drain before dispatch). N == 1 has no race so emits
// no delay — keeps the common path latency-free.

// Issue #64: delay constants are escape-hatchable via env vars.
// Defaults (0.3 / 0.5) are picked rather than measured; on a Mac under load
// (Time Machine, Spotlight reindex, dozen apps) or after Mail.app updates
// the timing window can shift. Without an escape hatch, a user reporting
// "still drops attachments 6 months from now" has no way to test calibration
// without a code change. Sane bounds (0–10s) prevent denial-of-self attacks.
private let defaultDelayBetween = 0.3
private let defaultDelayTrailing = 0.5

private func resolvedDelay(envKey: String, fallback: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[envKey],
          let value = Double(raw),
          value >= 0, value <= 10 else {
        return fallback
    }
    return value
}

private func attachmentFragment(for paths: [String]) -> String {
    guard !paths.isEmpty else { return "" }
    let lines = paths.map { path in
        "    make new attachment with properties {file name:POSIX file \"\(appleScriptEscape(path))\"} at after the last paragraph"
    }
    if paths.count == 1 {
        return lines[0]
    }
    let between = resolvedDelay(envKey: "CHE_MAIL_ATTACHMENT_DELAY_BETWEEN", fallback: defaultDelayBetween)
    let trailing = resolvedDelay(envKey: "CHE_MAIL_ATTACHMENT_DELAY_TRAILING", fallback: defaultDelayTrailing)
    var pieces: [String] = []
    for (idx, line) in lines.enumerated() {
        pieces.append(line)
        if idx < lines.count - 1 {
            pieces.append("    delay \(between)")
        }
    }
    pieces.append("    delay \(trailing)")
    return pieces.joined(separator: "\n")
}

private func recipientFragment(_ addresses: [String], kind: String) -> String {
    addresses.map { addr in
        "    make new \(kind) recipient at end of \(kind) recipients with properties {address:\"\(appleScriptEscape(addr))\"}"
    }.joined(separator: "\n")
}

// MARK: - #175 mailto-based clean-body compose (GUI orchestration)
//
// Builds the AppleScript that drives Mail's NATIVE compose pipeline via a
// `mailto:` hand-off (which, unlike `set content` / `set html content`, does NOT
// wrap the body in `Apple-Mail-URLShareWrapperClass` / `blockquote type="cite"`).
// The mailto window is NOT an AppleScript `outgoing message` object, so save/send
// and attachments are driven by System Events keystrokes.
//
// Locale-independence (avoids the #174-class hardcoded-string trap): EVERY step
// uses a keyboard SHORTCUT, never a localized menu-item name —
//   ⇧⌘A = File ▸ Attach,  ⇧⌘G = Go to folder,  ⌘S = save draft,  ⇧⌘D = send.
// These are identical across UI languages.
//
// Robustness (hardened per two #175 verify rounds — DA + Codex cross-model):
//   - WINDOW IDENTITY: before EVERY keystroke phase (each attach AND dispatch) we
//     re-locate the compose window BY TITLE (= subject; eligibility guarantees a
//     non-empty subject) and best-effort raise it, so a keystroke lands on OUR
//     window and not one the user opened/focused during a delay. A bare
//     window-count delta is NOT enough (`activate` can open a viewer). RESIDUAL
//     (documented): AX has no "send keystroke to a specific window" primitive, so
//     a TOCTOU gap between raise and keystroke remains — inherent to GUI
//     automation; a detectable mismatch (our window gone) hard-errors → fallback.
//   - ATTACHMENT COMPLETION: the pre-dispatch check asserts `count of sheets of
//     _w is 0`, so a still-open File▸Attach panel blocks dispatch; a drain delay
//     gives the attachment time to bind before ⇧⌘D. RESIDUAL: panel-closed is a
//     proxy for bind, not per-file completion polling.
//   - STAGE-AWARE FALLBACK + NO DATA LOSS: the GUI interaction is wrapped in
//     try/on-error that closes ONLY a window we created — identified by NEW
//     `id of window` (captured before the mailto) AND matching subject — so a
//     pre-existing same-titled draft the user already had open is never
//     `saving no` discarded (a data-loss bug the second verify round caught).
//     Dispatch is the last statement, so a pre-dispatch error means nothing was
//     sent (fallback safe; no double-send).
//   - CLIPBOARD: the per-attachment path is set on the clipboard here, but
//     save/restore is done by the caller in Swift (full-fidelity NSPasteboard,
//     failure-safe) — this script does NOT save/restore.
// Delays are env-overridable (#64 pattern) because GUI timing drifts under load.
func buildMailtoComposeScript(
    url: String,
    subject: String,
    attachments: [String],
    send: Bool
) -> String {
    let windowDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_WINDOW_DELAY", fallback: 1.8)
    let stepDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_STEP_DELAY", fallback: 0.7)
    let attachDrain = resolvedDelay(envKey: "CHE_MAIL_MAILTO_ATTACH_DRAIN", fallback: 1.5)
    let dispatchKey = send
        ? "keystroke \"d\" using {command down, shift down}"
        : "keystroke \"s\" using command down"
    let dispatchLabel = send
        ? "Email sent successfully (mailto path)"
        : "Draft created successfully (mailto path)"
    let subjEsc = appleScriptEscape(subject)

    // raiseOnly (runs inside `tell process "Mail"`): re-locate the compose window
    // BY TITLE (= subject) and best-effort raise it so the NEXT keystroke lands on
    // OUR window. Re-applied before EVERY keystroke phase (each attach + dispatch)
    // — focus the user/system stole during a delay is reclaimed. Hard-errors if
    // our window is gone (→ safe fallback). Keys off the target `_w`, never
    // `front window` (that evaluated unreliably under the actor's in-process
    // NSAppleScript context and regressed the path to always-fallback); AXRaise is
    // best-effort (wrapped) so an AX quirk can't break the path.
    let raiseOnly = """
                set _t to "\(subjEsc)"
                set _w to missing value
                repeat with _cand in windows
                    if title of _cand is _t then
                        set _w to _cand
                        exit repeat
                    end if
                end repeat
                if _w is missing value then error "mailto compose window not found (title)"
                try
                    perform action "AXRaise" of _w
                end try
                delay 0.25
    """
    // verifyNoSheet: raiseOnly + assert no open sheet (the File▸Attach panel must
    // have closed) — used immediately before dispatch.
    let verifyNoSheet = raiseOnly + """

                if (count of sheets of _w) is not 0 then error "a sheet/panel is still open on the compose window"
    """

    // 1. Capture Mail window ids BEFORE the mailto, hand it off, then compute the
    // NEW window id(s). On-error cleanup closes ONLY a newly-appeared window whose
    // name matches our subject — never a pre-existing same-titled draft the user
    // had open (that `saving no` discard would be data loss — #175 verify round 2,
    // Codex BLOCKING). `id of window` is stable + unique.
    var s = """
    tell application "Mail"
        set _wc to (count of windows)
        set _beforeIds to (id of every window)
        activate
        mailto "\(appleScriptEscape(url))"
    end tell
    delay \(windowDelay)
    tell application "Mail"
        if (count of windows) <= _wc then error "mailto did not open a compose window"
        set _afterIds to (id of every window)
        set _newIds to {}
        repeat with _k from 1 to (count of _afterIds)
            set _thisId to item _k of _afterIds
            if _beforeIds does not contain _thisId then set end of _newIds to _thisId
        end repeat
    end tell
    try
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
    \(raiseOnly)
            end tell
        end tell
    """

    // 2. Attachments: re-raise OUR window, then one File ▸ Attach (⇧⌘A) cycle each,
    // path pasted into the Go-to-folder (⇧⌘G) field (CJK-safe; clipboard set here,
    // restored by the caller in Swift).
    if !attachments.isEmpty {
        for path in attachments {
            s += """

            tell application "System Events"
                tell process "Mail"
                    set frontmost to true
                    \(raiseOnly)
                    keystroke "a" using {command down, shift down}
                end tell
            end tell
            delay \(stepDelay)
            set the clipboard to "\(appleScriptEscape(path))"
            tell application "System Events"
                tell process "Mail"
                    keystroke "g" using {command down, shift down}
                    delay \(stepDelay)
                    keystroke "v" using command down
                    delay 0.4
                    key code 36
                    delay \(stepDelay)
                    key code 36
                end tell
            end tell
            delay \(stepDelay)
            """
        }
        // Drain: give the attachment(s) time to bind before dispatch (#60-style).
        s += "\n        delay \(attachDrain)\n"
    }

    // 3. Final re-raise + no-lingering-panel check + dispatch.
    s += """

        tell application "System Events"
            tell process "Mail"
                set frontmost to true
    \(verifyNoSheet)
                \(dispatchKey)
            end tell
        end tell
    on error _mErr
        tell application "Mail"
            repeat with _k from 1 to (count of _newIds)
                set _nid to item _k of _newIds
                try
                    set _cw to (first window whose id is _nid)
                    if (name of _cw) is "\(subjEsc)" then close _cw saving no
                end try
            end repeat
        end tell
        error _mErr
    end try
    delay \(stepDelay)
    return "\(dispatchLabel)"
    """
    return s
}

func buildComposeEmailScript(
    to: [String],
    subject: String,
    body: String,
    cc: [String]? = nil,
    bcc: [String]? = nil,
    attachments: [String]? = nil,
    format: BodyFormat = .plain,
    sanitizeLinks: Bool = false,
    fromAddress: String? = nil
) throws -> String {
    let composed = try renderBody(body, format: format, sanitizeLinks: sanitizeLinks)
    let plainFallback = composed.plainContent

    var script = """
    tell application "Mail"
        set newMessage to make new outgoing message with properties {subject:"\(appleScriptEscape(subject))", content:"\(appleScriptEscape(plainFallback))", visible:true}
        tell newMessage
    """

    // #131: sender account selection. Mail.app's outgoing-message `sender`
    // property is a STRING matching one of the user's configured email
    // addresses (RFC 5322 addr-spec, optionally with display name —
    // `"Name <email@example.com>"`). NOT an `account id` selector — Mail.app
    // routes outgoing messages by matching `sender` against configured
    // accounts. Omitted: Mail.app uses the default account (backward compat
    // — script remains byte-identical to pre-#131 output).
    if let from = fromAddress, !from.isEmpty {
        script += "\n        set sender to \"\(appleScriptEscape(from))\""
    }

    if let html = composed.htmlContent {
        script += "\n        set html content to \"\(appleScriptEscape(html))\""
    }

    script += "\n" + recipientFragment(to, kind: "to")
    if let cc = cc { script += "\n" + recipientFragment(cc, kind: "cc") }
    if let bcc = bcc { script += "\n" + recipientFragment(bcc, kind: "bcc") }
    if let attachments = attachments { script += "\n" + attachmentFragment(for: attachments) }

    script += "\n" + """
        end tell
        send newMessage
        return "Email sent successfully"
    end tell
    """

    return script
}

func buildCreateDraftScript(
    to: [String],
    subject: String,
    body: String,
    cc: [String]? = nil,
    bcc: [String]? = nil,
    attachments: [String]? = nil,
    format: BodyFormat = .plain,
    sanitizeLinks: Bool = false,
    fromAddress: String? = nil
) throws -> String {
    let composed = try renderBody(body, format: format, sanitizeLinks: sanitizeLinks)
    let plainFallback = composed.plainContent

    var script = """
    tell application "Mail"
        set newMessage to make new outgoing message with properties {subject:"\(appleScriptEscape(subject))", content:"\(appleScriptEscape(plainFallback))", visible:true}
        tell newMessage
    """

    // #131: sender account selection — see buildComposeEmailScript above.
    if let from = fromAddress, !from.isEmpty {
        script += "\n        set sender to \"\(appleScriptEscape(from))\""
    }

    if let html = composed.htmlContent {
        script += "\n        set html content to \"\(appleScriptEscape(html))\""
    }

    script += "\n" + recipientFragment(to, kind: "to")
    // cc / bcc emission order mirrors buildComposeEmailScript (#107).
    if let cc = cc { script += "\n" + recipientFragment(cc, kind: "cc") }
    if let bcc = bcc { script += "\n" + recipientFragment(bcc, kind: "bcc") }
    if let attachments = attachments { script += "\n" + attachmentFragment(for: attachments) }

    script += "\n" + """
        end tell
        save newMessage
        return "Draft created successfully"
    end tell
    """

    return script
}

func composeReplyHTML(userBody: String, userFormat: BodyFormat, originalHTML: String?, originalPlain: String, sanitizeLinks: Bool = false) throws -> String {
    let composed = try renderBody(userBody, format: userFormat, sanitizeLinks: sanitizeLinks)
    let userPart = composed.htmlContent ?? htmlEscape(userBody)

    let quoted: String
    if let html = originalHTML, !html.isEmpty {
        quoted = html
    } else {
        quoted = htmlEscape(originalPlain).replacingOccurrences(of: "\n", with: "<br>\n")
    }

    return "\(userPart)\n<hr>\n<blockquote>\n\(quoted)\n</blockquote>"
}

// Issue #43: AppleScript `& content` against a freshly-created outgoing message
// returns empty before the GUI compose pipeline materializes the quoted body.
// We pre-fetch the original plain text and Swift-side compose RFC 3676 quoted
// reply body so the result is deterministic regardless of window state.
//
// Round-1 hardening (#43 verify findings — Logic #1/2/3/5, Codex P1/P3):
// - Normalize CRLF/CR → LF before splitting (Mail.app IMAP/Exchange messages
//   sometimes return CRLF line endings).
// - Strip trailing newlines (Mail.app commonly appends a trailing newline,
//   which would emit a stray `> ` line at the end).
// - For empty quoted lines, emit `>` (no trailing space) per RFC 3676 §4.5;
//   only non-empty lines get the `> ` stuffing space.
// - After normalization, if there is no quotable content (e.g. originalPlain
//   was just whitespace/newlines), return userBody alone.
func composeReplyPlainText(userBody: String, originalPlain: String) -> String {
    let normalized = originalPlain
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    var trimmed = Substring(normalized)
    while let last = trimmed.last, last == "\n" {
        trimmed = trimmed.dropLast()
    }
    if trimmed.isEmpty {
        return userBody
    }
    let quoted = trimmed
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? ">" : "> \($0)" }
        .joined(separator: "\n")
    return "\(userBody)\n\n\(quoted)"
}

func buildReplyEmailScript(
    messageRef: String,
    userBody: String,
    userFormat: BodyFormat,
    replyAll: Bool,
    ccAdditional: [String]? = nil,
    attachments: [String]? = nil,
    saveAsDraft: Bool = false,
    originalHTML: String?,
    originalPlain: String,
    sanitizeLinks: Bool = false
) throws -> String {
    let replyType = replyAll ? "reply all" : "reply"
    let dispatchVerb = saveAsDraft ? "save" : "send"
    let returnMessage = saveAsDraft ? "Reply saved as draft" : "Reply sent successfully"
    // saveAsDraft=true: don't open Mail.app GUI window. The user wanted a quiet
    // draft for later review; popping a window invites them to edit it directly
    // and lose the saved snapshot. saveAsDraft=false: keep the existing
    // send-path behavior (window briefly opens during send, backward compat).
    let windowClause = saveAsDraft ? "without opening window" : "with opening window"

    let extraTellLines: String = {
        var lines: [String] = []
        if let cc = ccAdditional, !cc.isEmpty {
            lines.append(recipientFragment(cc, kind: "cc"))
        }
        if let atts = attachments, !atts.isEmpty {
            lines.append(attachmentFragment(for: atts))
        }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }()

    if userFormat == .plain {
        let composedPlain = composeReplyPlainText(userBody: userBody, originalPlain: originalPlain)
        return """
        tell application "Mail"
            set originalMsg to \(messageRef)
            set replyMsg to \(replyType) originalMsg \(windowClause)
            tell replyMsg
                set content to "\(appleScriptEscape(composedPlain))"\(extraTellLines)
            end tell
            \(dispatchVerb) replyMsg
            return "\(returnMessage)"
        end tell
        """
    }

    let finalHTML = try composeReplyHTML(
        userBody: userBody,
        userFormat: userFormat,
        originalHTML: originalHTML,
        originalPlain: originalPlain,
        sanitizeLinks: sanitizeLinks
    )

    return """
    tell application "Mail"
        set originalMsg to \(messageRef)
        set replyMsg to \(replyType) originalMsg \(windowClause)
        tell replyMsg
            set html content to "\(appleScriptEscape(finalHTML))"\(extraTellLines)
        end tell
        \(dispatchVerb) replyMsg
        return "\(returnMessage)"
    end tell
    """
}

func buildForwardEmailScript(
    messageRef: String,
    to: [String],
    userBody: String?,
    userFormat: BodyFormat,
    originalHTML: String?,
    originalPlain: String?,
    sanitizeLinks: Bool = false
) throws -> String {
    var script = """
    tell application "Mail"
        set originalMsg to \(messageRef)
        set fwdMsg to forward originalMsg with opening window
        tell fwdMsg
    """

    script += "\n" + recipientFragment(to, kind: "to")

    if let body = userBody {
        if userFormat == .plain {
            // Issue #44 (mirrors #43): use Swift-side composeReplyPlainText helper
            // instead of broken `& content` AppleScript. The pre-fix pattern read
            // outgoing message's `content` as empty before Mail.app's GUI populated
            // the quoted body — every plain forward since b8a4a89 silently dropped
            // the quoted original.
            let composedPlain = composeReplyPlainText(userBody: body, originalPlain: originalPlain ?? "")
            script += "\n" + """
                set content to "\(appleScriptEscape(composedPlain))"
            """
        } else {
            let finalHTML = try composeReplyHTML(
                userBody: body,
                userFormat: userFormat,
                originalHTML: originalHTML,
                originalPlain: originalPlain ?? "",
                sanitizeLinks: sanitizeLinks
            )
            script += "\n" + """
                set html content to "\(appleScriptEscape(finalHTML))"
            """
        }
    }

    script += "\n" + """
        end tell
        send fwdMsg
        return "Email forwarded successfully"
    end tell
    """

    return script
}

/// #134 — testable seam for reply_email's resolveMsgRef wiring.
///
/// Pre-#134 `MailController.replyEmail` computed `ref = resolveMsgRef(...)`
/// inline and threaded `ref` into the `(messageRef:)` builder. That overload
/// is byte-identical to what the actor produces, but the wiring step (the
/// literal `resolveMsgRef` call that #104 PR-C added for account_id
/// disambiguation) had **no automated regression lock** — reverting it to
/// the legacy `msgRef(...)` helper would leave `swift test` green and
/// silently bring back the #104 display_name-collision bug.
///
/// This overload internalizes the `resolveMsgRef` call so the wiring IS
/// unit-testable: `buildReplyEmailScript(id:..., accountId: uuid, ...)`
/// must emit `(account id "<UUID>")`, and the existing
/// `buildReplyEmailScript(messageRef:...)` overload stays intact for the
/// 25 legacy tests that pre-build the ref themselves.
///
/// `MailController.replyEmail` MUST use this overload (not the `messageRef:`
/// one with an inline `msgRef(...)` call) — that's the discipline this seam
/// codifies. Pre-fetch path still computes `ref` inline because it threads
/// through `buildFetchOriginalContentScript`; #134's scope is the main
/// reply script wiring (sibling issue can extend to the fetch path).
func buildReplyEmailScript(
    id: String,
    mailbox: String,
    accountId: String?,
    accountName: String,
    userBody: String,
    userFormat: BodyFormat,
    replyAll: Bool,
    ccAdditional: [String]? = nil,
    attachments: [String]? = nil,
    saveAsDraft: Bool = false,
    originalHTML: String?,
    originalPlain: String,
    sanitizeLinks: Bool = false
) throws -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox,
                            accountId: accountId, accountName: accountName)
    return try buildReplyEmailScript(
        messageRef: ref,
        userBody: userBody,
        userFormat: userFormat,
        replyAll: replyAll,
        ccAdditional: ccAdditional,
        attachments: attachments,
        saveAsDraft: saveAsDraft,
        originalHTML: originalHTML,
        originalPlain: originalPlain,
        sanitizeLinks: sanitizeLinks
    )
}

/// #134 — testable seam for forward_email's resolveMsgRef wiring.
/// See `buildReplyEmailScript(id:mailbox:accountId:accountName:...)` for
/// the rationale; mirrors that pattern for forward.
func buildForwardEmailScript(
    id: String,
    mailbox: String,
    accountId: String?,
    accountName: String,
    to: [String],
    userBody: String?,
    userFormat: BodyFormat,
    originalHTML: String?,
    originalPlain: String?,
    sanitizeLinks: Bool = false
) throws -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox,
                            accountId: accountId, accountName: accountName)
    return try buildForwardEmailScript(
        messageRef: ref,
        to: to,
        userBody: userBody,
        userFormat: userFormat,
        originalHTML: originalHTML,
        originalPlain: originalPlain,
        sanitizeLinks: sanitizeLinks
    )
}

func buildFetchOriginalContentScript(messageRef: String) -> String {
    return """
    tell application "Mail"
        set originalMsg to \(messageRef)
        try
            set originalHTML to html content of originalMsg
        on error
            set originalHTML to ""
        end try
        set originalPlain to content of originalMsg
        return originalHTML & "\u{001E}\u{001E}\u{001E}" & originalPlain
    end tell
    """
}

func parseFetchedOriginalContent(_ raw: String) -> (html: String?, plain: String) {
    let sep = "\u{001E}\u{001E}\u{001E}"
    let parts = raw.components(separatedBy: sep)
    if parts.count >= 2 {
        let html = parts[0]
        let plain = parts[1...].joined(separator: sep)
        return (html.isEmpty ? nil : html, plain)
    }
    return (nil, raw)
}
