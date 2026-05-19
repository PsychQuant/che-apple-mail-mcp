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
