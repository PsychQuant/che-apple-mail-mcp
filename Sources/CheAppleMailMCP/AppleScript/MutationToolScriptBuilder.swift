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
/// `junk mail status` is a flag. Setting it issues no move: in #689 a message in
/// the junk mailbox stayed there while the tool answered "marked as not junk".
/// The script therefore returns no success sentence of its own. It returns what
/// Mail reports for the flag after the change (`true` / `false`), or `unknown`
/// when that read fails; the caller turns it into a report with `markAsJunkReport`.
///
/// The message is resolved once into `msg` (the same shape `move_email` uses), so
/// the read-back does not search for it again. `msg` is scoped to the mailbox the
/// caller addressed, which is why a read-back that succeeds is evidence that Mail
/// still found the message in that mailbox at that moment. The read-back is inside
/// a `try` so that a failed read does not turn a change that succeeded into an
/// error. A script that runs past the runner's time limit still fails as a timeout.
func buildMarkAsJunkScript(id: String, mailbox: String, accountId: String?, accountName: String, isJunk: Bool) -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set msg to \(ref)
        set junk mail status of msg to \(isJunk)
        set flagNow to "unknown"
        try
            if junk mail status of msg then
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
/// - Read back as requested: the value Mail reports, that the tool issued no
///   move, and that Mail still found the message in the addressed mailbox when
///   the flag was read back. That last part is what the read-back shows (the
///   reference is scoped to that mailbox); it says nothing about later.
/// - Read back as the opposite value: an error, not a success.
/// - Not read back: no flag value and no mailbox are stated as fact. The likely
///   cause is that the message is no longer at that address, so the caller is
///   told to search for it again before moving it.
///
/// `mailbox` is the caller's own argument, repeated to the caller; it does not
/// go into the script from here.
func markAsJunkReport(requested: Bool, readBack: JunkStatusReadBack, mailbox: String) throws -> String {
    let foundThere = "Mail still found the message in mailbox \"\(mailbox)\" when the flag was read back."
    switch readBack {
    case .value(let now) where now == requested:
        return "Mail reports junk mail status \(now) after the change. "
            + "mark_as_junk changes the flag only: it issued no move, and \(foundThere) "
            + "To move it, call move_email."
    case .value(let now):
        throw MailError.operationFailed(
            "Mail still reports junk mail status \(now) after it was set to \(requested). "
            + "mark_as_junk issued no move, and \(foundThere)")
    case .unknown:
        return "Junk mail status was set to \(requested), but it could not be read back from mailbox \"\(mailbox)\". "
            + "mark_as_junk changes the flag only and issued no move. If Mail moved the message on its own, "
            + "the message has a new id: search for it again before calling move_email."
    }
}
