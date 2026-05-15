import Foundation

/// AppleScript builders for `save_attachment` with account-UUID disambiguation
/// (resolving the multi-account-same-display_name defect, #101).
///
/// AppleScript syntax for `account id "..."` was verified empirically on
/// macOS 14 (2026-05-15):
///
/// ```applescript
/// tell application "Mail"
///     set m to first mailbox of (account id "<UUID>") whose name is "INBOX"
///     return name of m
/// end tell
/// -- → "INBOX"  (positive case)
/// -- → -1719 "索引錯誤" when mailbox name doesn't exist under that account
/// -- → -1728 when UUID doesn't match any account
/// ```
///
/// Both error modes match the existing display_name path's error codes
/// (`-1719` / `-1728`), so error-handling code in `MailController.runScript`
/// continues to apply unchanged.
///
/// Free functions (not methods on `MailController`) so they're testable
/// without spinning up the actor — same pattern as `ComposeScriptBuilder.swift`.

/// Build an AppleScript reference to a mailbox using the account's globally
/// unique UUID. Avoids the display_name ambiguity that plagues
/// `account "<display_name>"` selectors when multiple accounts share the
/// same display name (#101 root cause).
///
/// - Parameters:
///   - mailbox: Mailbox name (e.g. "INBOX", "[Gmail]/全部郵件"). Escaped via `appleScriptEscape`.
///   - accountId: Account UUID from `mailboxes.account_id` SQLite join /
///     `AccountMapper`. Caller must ensure non-empty — pass through
///     `buildSaveAttachmentScript` for empty-handling.
/// - Returns: `(first mailbox of (account id "<escaped UUID>") whose name is "<escaped mailbox>")`
func mailboxRefByAccountId(_ mailbox: String, accountId: String) -> String {
    return "(first mailbox of (account id \"\(appleScriptEscape(accountId))\") whose name is \"\(appleScriptEscape(mailbox))\")"
}

/// Build an AppleScript reference to a message by ROWID, using account UUID
/// for disambiguation. See `mailboxRefByAccountId` for the syntax rationale.
///
/// - Note: Apple Mail's `id` of a message is a numeric internal identifier
///   (not the RFC 822 Message-ID string), so `whose id is <N>` is
///   interpolated unquoted. `assert` catches non-numeric `id` at debug
///   time — Server-layer `requireMessageId` is the user-facing contract.
func msgRefByAccountId(_ id: String, mailbox: String, accountId: String) -> String {
    assert(Int(id) != nil, "msgRefByAccountId called with non-numeric id '\(id)' — Server.swift handler missed validation (#50)")
    return "(first message of \(mailboxRefByAccountId(mailbox, accountId: accountId)) whose id is \(id))"
}

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
    let msgRef: String
    if let aid = accountId, !aid.isEmpty {
        msgRef = msgRefByAccountId(id, mailbox: mailbox, accountId: aid)
    } else {
        // Legacy fallback — same shape as MailController's private
        // msgRef(_:mailbox:account:) but inlined so the actor doesn't need
        // to expose its privates. Behavior intentionally identical to
        // pre-#101 path.
        let escapedAcct = appleScriptEscape(accountName)
        let escapedMbx = appleScriptEscape(mailbox)
        msgRef = "(first message of (first mailbox of account \"\(escapedAcct)\" whose name is \"\(escapedMbx)\") whose id is \(id))"
    }
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
