import Foundation

/// AppleScript builder for `redirect_email` (#104 PR-C).
///
/// `redirect` keeps the original sender (unlike `forward`, which composes a
/// new message from the user). The script references exactly one existing
/// message — a single `msgRef`, matching PR-A's single-ref mutation pattern.
///
/// Before PR-C this script was built inline in `MailController.redirectEmail`.
/// Extracting it into a free builder makes the `account_id` UUID path
/// unit-testable without spinning up the actor — same rationale as
/// `MoveCopyDeleteScriptBuilder` (PR-B) and `MutationToolScriptBuilder` (PR-A).
///
/// When `accountId` is non-nil and non-empty, `resolveMsgRef` emits the
/// globally-unique `(account id "<UUID>")` selector; otherwise it falls back
/// to the legacy `account "<display_name>"` form — byte-identical to the
/// pre-PR-C inline script.
func buildRedirectEmailScript(
    id: String,
    mailbox: String,
    accountId: String?,
    accountName: String,
    to: [String]
) -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)

    var script = """
    tell application "Mail"
        set originalMsg to \(ref)
        set redirectMsg to redirect originalMsg with opening window
        tell redirectMsg
    """

    for recipient in to {
        script += "\n" + """
            make new to recipient at end of to recipients with properties {address:"\(appleScriptEscape(recipient))"}
        """
    }

    script += "\n" + """
        end tell
        send redirectMsg
        return "Email redirected successfully"
    end tell
    """

    return script
}
