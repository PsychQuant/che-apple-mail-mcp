import Foundation

/// AppleScript builders for the 5 single-message mutation tools, with
/// account-UUID disambiguation (#104 PR-A).
///
/// Each builder resolves its message reference via `resolveMsgRef`
/// (`AppleScriptRefBuilder.swift`): `(account id "<UUID>")` selector when
/// `accountId` is supplied, legacy `account "<display_name>"` form when
/// nil/empty. Free functions so they're testable without the actor —
/// same pattern as `ComposeScriptBuilder` / `SaveAttachmentScriptBuilder`.

/// `mark_read` — set the read status of a message.
func buildMarkReadScript(id: String, mailbox: String, accountId: String?, accountName: String, read: Bool) -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set read status of \(ref) to \(read)
        return "Email marked as \(read ? "read" : "unread")"
    end tell
    """
}

/// `flag_email` — set the flagged status of a message.
func buildFlagEmailScript(id: String, mailbox: String, accountId: String?, accountName: String, flagged: Bool) -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set flagged status of \(ref) to \(flagged)
        return "Email \(flagged ? "flagged" : "unflagged")"
    end tell
    """
}

/// `set_flag_color` — set the flag index (color) of a message.
func buildSetFlagColorScript(id: String, mailbox: String, accountId: String?, accountName: String, colorIndex: Int) -> String {
    let colors = ["red", "orange", "yellow", "green", "blue", "purple", "gray"]
    let colorName = colorIndex >= 0 && colorIndex < colors.count ? colors[colorIndex] : "none"
    let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set flag index of \(ref) to \(colorIndex)
        return "Flag color set to \(colorName)"
    end tell
    """
}

/// Canonical whitelist of Apple Mail background colors (#116 — AppleScript
/// injection hardening). Single source of truth used by both
/// `Server.swift`'s `set_background_color` handler (user-facing reject with
/// `MailError.invalidParameter`) and `buildSetBackgroundColorScript` below
/// (defense-in-depth `precondition`).
///
/// Membership is lowercase-strict and exact-match — no case-folding, no
/// trim. Drift between this constant and `Server.swift`'s schema description
/// (`Sources/CheAppleMailMCP/Server.swift:467,475`) is a bug;
/// `MutationToolScriptBuilderTests.testBackgroundColorWhitelist_containsAllAppleMailEnumValues`
/// pins it.
let backgroundColorWhitelist: Set<String> = [
    "blue", "gray", "green", "none", "orange", "purple", "red", "yellow"
]

/// `set_background_color` — set the background color of a message.
///
/// `color` is interpolated raw into AppleScript at the `to \(color)` line, so
/// callers MUST pass a value in `backgroundColorWhitelist`. The `precondition`
/// is defense-in-depth; the user-facing reject lives in the handler. A
/// precondition firing here means a programmer (test, internal refactor)
/// bypassed the handler gate — better to crash than silently inject.
func buildSetBackgroundColorScript(id: String, mailbox: String, accountId: String?, accountName: String, color: String) -> String {
    precondition(backgroundColorWhitelist.contains(color),
                 "buildSetBackgroundColorScript called with non-whitelisted color '\(color)' — "
                 + "Server.swift handler must guard via backgroundColorWhitelist before delegating (#116)")
    let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set background color of \(ref) to \(color)
        return "Background color set to \(color)"
    end tell
    """
}

/// `mark_as_junk` — set the junk mail status of a message, then read it back.
///
/// `junk mail status` is a flag. Setting it does not move the message: a message
/// in the junk mailbox stays there (#689). The script therefore returns no
/// success sentence of its own. It returns what Mail reports for the flag after
/// the change (`true` / `false`), or `unknown` when that read fails; the caller
/// turns it into a report with `markAsJunkReport`. The read-back is inside a
/// `try` so that a failed read does not turn a change that succeeded into an error.
func buildMarkAsJunkScript(id: String, mailbox: String, accountId: String?, accountName: String, isJunk: Bool) -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set junk mail status of \(ref) to \(isJunk)
        set flagNow to "unknown"
        try
            if junk mail status of \(ref) then
                set flagNow to "true"
            else
                set flagNow to "false"
            end if
        end try
        return flagNow
    end tell
    """
}

/// What Mail reported for a message's junk mail status after `mark_as_junk` set it.
enum JunkStatusReadBack: Equatable {
    case value(Bool)
    /// The read failed, or the script returned something other than `true` / `false`.
    case unknown
}

/// Read the output of `buildMarkAsJunkScript`. Anything other than `true` or
/// `false` is `unknown`: it is never guessed into a status.
func parseJunkStatusReadBack(_ output: String) -> JunkStatusReadBack {
    switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "true": return .value(true)
    case "false": return .value(false)
    default: return .unknown
    }
}

/// The result `mark_as_junk` returns (#689).
///
/// It states the flag as read back and that the tool did not move the message.
/// It names the mailbox the message was ADDRESSED in, not where the message is
/// now: the tool does not look that up, and Mail may move a message on its own.
/// A read-back opposite to the request is an error, not a success.
func markAsJunkReport(requested: Bool, readBack: JunkStatusReadBack, mailbox: String) throws -> String {
    let flagOnly = "mark_as_junk changes the flag only: it did not move the message, "
        + "which was addressed in mailbox \"\(mailbox)\". To move it, call move_email."
    switch readBack {
    case .value(let now) where now == requested:
        return "Junk mail status is now \(now). \(flagOnly)"
    case .value(let now):
        throw MailError.operationFailed(
            "Mail still reports junk mail status \(now) after it was set to \(requested). "
            + "The message was addressed in mailbox \"\(mailbox)\" and was not moved.")
    case .unknown:
        return "Junk mail status was set to \(requested), but it could not be read back. \(flagOnly)"
    }
}
