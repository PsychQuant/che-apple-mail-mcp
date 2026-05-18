import Foundation

/// AppleScript builders for the 3 movement/destruction tools, with account-UUID
/// disambiguation (#104 PR-B).
///
/// `move_email` / `copy_email` emit TWO references — source `msgRef` (via
/// `resolveMsgRef`) AND destination `mailboxRef` (via `resolveMailboxRef`).
/// Both refs go through the same `accountId` since move/copy are within a
/// single account. `delete_email` has only ONE ref, matching PR-A's single-
/// mailbox mutation pattern.
///
/// All three delegate account resolution to `AppleScriptRefBuilder.swift`'s
/// chokepoint: `(account id "<UUID>")` when `accountId` is non-empty, legacy
/// `account "<display_name>"` form otherwise. Free functions so they're
/// testable without the actor — same pattern as `MutationToolScriptBuilder`
/// / `ComposeScriptBuilder` / `SaveAttachmentScriptBuilder`.

/// `move_email` — move a message to another mailbox in the same account.
func buildMoveEmailScript(
    id: String, fromMailbox: String, toMailbox: String,
    accountId: String?, accountName: String
) -> String {
    let sourceRef = resolveMsgRef(id: id, mailbox: fromMailbox,
                                  accountId: accountId, accountName: accountName)
    let destRef = resolveMailboxRef(mailbox: toMailbox,
                                    accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set msg to \(sourceRef)
        move msg to \(destRef)
        return "Email moved to \(appleScriptEscape(toMailbox))"
    end tell
    """
}

/// `copy_email` — duplicate a message to another mailbox in the same account.
func buildCopyEmailScript(
    id: String, fromMailbox: String, toMailbox: String,
    accountId: String?, accountName: String
) -> String {
    let sourceRef = resolveMsgRef(id: id, mailbox: fromMailbox,
                                  accountId: accountId, accountName: accountName)
    let destRef = resolveMailboxRef(mailbox: toMailbox,
                                    accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set msg to \(sourceRef)
        duplicate msg to \(destRef)
        return "Email copied to \(appleScriptEscape(toMailbox))"
    end tell
    """
}

/// `delete_email` — move a message to Trash (Mail.app semantic).
func buildDeleteEmailScript(
    id: String, mailbox: String,
    accountId: String?, accountName: String
) -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox,
                            accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        delete \(ref)
        return "Email deleted"
    end tell
    """
}
