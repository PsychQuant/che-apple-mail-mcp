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

/// `set_background_color` — set the background color of a message.
func buildSetBackgroundColorScript(id: String, mailbox: String, accountId: String?, accountName: String, color: String) -> String {
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
