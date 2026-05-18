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

/// `mark_as_junk` — set the junk mail status of a message.
func buildMarkAsJunkScript(id: String, mailbox: String, accountId: String?, accountName: String, isJunk: Bool) -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set junk mail status of \(ref) to \(isJunk)
        return "Email marked as \(isJunk ? "junk" : "not junk")"
    end tell
    """
}
