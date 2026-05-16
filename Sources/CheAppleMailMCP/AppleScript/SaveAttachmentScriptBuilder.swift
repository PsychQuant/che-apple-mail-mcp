import Foundation

/// AppleScript builder for `save_attachment` with account-UUID disambiguation
/// (resolving the multi-account-same-display_name defect, #101).
///
/// The account-reference primitives (`mailboxRefByAccountId`,
/// `msgRefByAccountId`, `resolveMsgRef`, `resolveMailboxRef`) live in
/// `AppleScriptRefBuilder.swift` — shared by the #104 disambiguation sweep.
/// This file keeps only the `save_attachment`-specific script assembly.
///
/// Free function (not a method on `MailController`) so it's testable
/// without spinning up the actor — same pattern as `ComposeScriptBuilder.swift`.

/// Build the full `save_attachment` AppleScript, preferring `accountId`
/// (UUID) when available and falling back to `accountName` (display_name)
/// for backward compatibility.
///
/// - Parameters:
///   - id: Message ROWID (numeric, validated upstream).
///   - mailbox: Mailbox name.
///   - accountId: Optional account UUID. When non-nil AND non-empty, the
///     script uses Mail.app's `(account id "...")` selector — globally
///     unique, no collision risk. Otherwise falls back to the legacy
///     `account "<display_name>"` form.
///   - accountName: Display name. Always emitted in fallback path; ignored
///     in UUID path (still kept in the signature so callers always pass it
///     and Server.swift schema remains forward-compatible).
///   - attachmentName: Attachment filename to match (case-sensitive).
///   - savePath: POSIX file path to write the attachment to.
/// - Returns: A complete AppleScript program (string), ready for
///   `MailController.runScript(...)`.
func buildSaveAttachmentScript(
    id: String,
    mailbox: String,
    accountId: String?,
    accountName: String,
    attachmentName: String,
    savePath: String
) -> String {
    let msgRef = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    let escapedAttName = appleScriptEscape(attachmentName)
    let escapedPath = appleScriptEscape(savePath)
    return """
    tell application "Mail"
        set msg to \(msgRef)
        repeat with att in mail attachments of msg
            if name of att is "\(escapedAttName)" then
                save att in POSIX file "\(escapedPath)"
                return "Attachment saved to \(escapedPath)"
            end if
        end repeat
        return "Attachment not found"
    end tell
    """
}
