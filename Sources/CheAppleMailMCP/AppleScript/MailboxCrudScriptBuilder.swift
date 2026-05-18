import Foundation

/// AppleScript builders for mailbox CRUD — `create_mailbox` / `delete_mailbox`
/// (#104 PR-D, the final increment of the account_id disambiguation sweep).
///
/// The two tools need DIFFERENT resolvers:
///
/// - `buildCreateMailboxScript` addresses an account **directly** —
///   `make new mailbox ... at <accountRef>` — so it uses `resolveAccountRef`,
///   which emits just the account selector (`(account id "<UUID>")` or
///   `account "<display_name>"`).
/// - `buildDeleteMailboxScript` references an **existing mailbox** —
///   `delete <mailboxRef>` — so it uses the established `resolveMailboxRef`
///   chokepoint, same as PR-B's move/copy/delete.
///
/// When `accountId` is non-nil/non-empty the resolvers emit the globally-unique
/// UUID selector; otherwise they fall back to the legacy display_name form —
/// byte-identical to the pre-PR-D inline scripts in `MailController`.

func buildCreateMailboxScript(name: String, accountId: String?, accountName: String) -> String {
    let accountRef = resolveAccountRef(accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        make new mailbox with properties {name:"\(appleScriptEscape(name))"} at \(accountRef)
        return "Created mailbox: \(appleScriptEscape(name))"
    end tell
    """
}

func buildDeleteMailboxScript(name: String, accountId: String?, accountName: String) -> String {
    let mailboxRef = resolveMailboxRef(mailbox: name, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        delete \(mailboxRef)
        return "Deleted mailbox: \(appleScriptEscape(name))"
    end tell
    """
}
