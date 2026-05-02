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

// Issue #39: both fragment helpers emit consistent 4-space indent for
// readable AppleScript output. Callers concatenate without adding extra
// indent prefixes (previous code added "        " for attachments only,
// causing visual mismatch in emitted scripts).

private func attachmentFragment(for paths: [String]) -> String {
    paths.map { path in
        "    make new attachment with properties {file name:POSIX file \"\(appleScriptEscape(path))\"} at after the last paragraph"
    }.joined(separator: "\n")
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
    format: BodyFormat = .plain
) throws -> String {
    let composed = try renderBody(body, format: format)
    let plainFallback = composed.plainContent

    var script = """
    tell application "Mail"
        set newMessage to make new outgoing message with properties {subject:"\(appleScriptEscape(subject))", content:"\(appleScriptEscape(plainFallback))", visible:true}
        tell newMessage
    """

    if let html = composed.htmlContent {
        script += "\n        set html content to \"\(appleScriptEscape(html))\""
    }

    script += "\n" + recipientFragment(to, kind: "to")
    if let cc = cc { script += "\n" + recipientFragment(cc, kind: "cc") }
    if let bcc = bcc { script += "\n" + recipientFragment(bcc, kind: "bcc") }
    if let attachments = attachments { script += "\n        " + attachmentFragment(for: attachments) }

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
    attachments: [String]? = nil,
    format: BodyFormat = .plain
) throws -> String {
    let composed = try renderBody(body, format: format)
    let plainFallback = composed.plainContent

    var script = """
    tell application "Mail"
        set newMessage to make new outgoing message with properties {subject:"\(appleScriptEscape(subject))", content:"\(appleScriptEscape(plainFallback))", visible:true}
        tell newMessage
    """

    if let html = composed.htmlContent {
        script += "\n        set html content to \"\(appleScriptEscape(html))\""
    }

    script += "\n" + recipientFragment(to, kind: "to")
    if let attachments = attachments { script += "\n        " + attachmentFragment(for: attachments) }

    script += "\n" + """
        end tell
        save newMessage
        return "Draft created successfully"
    end tell
    """

    return script
}

func composeReplyHTML(userBody: String, userFormat: BodyFormat, originalHTML: String?, originalPlain: String) throws -> String {
    let composed = try renderBody(userBody, format: userFormat)
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
    originalPlain: String
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
        originalPlain: originalPlain
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
    originalPlain: String?
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
                originalPlain: originalPlain ?? ""
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
