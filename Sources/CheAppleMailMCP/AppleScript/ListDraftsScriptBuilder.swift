import Foundation

/// AppleScript builder for `list_drafts` (#174) — per-account drafts
/// resolution via the unified `drafts mailbox`'s per-account children.
///
/// The pre-#174 implementation hardcoded `whose name is "Drafts"`, which can
/// never match a Gmail account's localized drafts mailbox (`[Gmail]/草稿`,
/// AppleScript leaf name `草稿`) and failed with -1719 — the only hardcoded
/// special-mailbox name in the repo.
///
/// Why this shape (empirically verified 2026-06-11 against a live Gmail
/// account, issue #174 plan):
/// - `drafts mailbox of (account id "...")` does NOT exist (-1728) — Mail
///   exposes special mailboxes per-account only as children of the app-level
///   unified mailbox.
/// - `every mailbox of drafts mailbox` returns one child per account, and
///   `id of account of mb` / `name of account of mb` resolve on each child —
///   a localization- and provider-independent match key (iCloud "Drafts" and
///   Gmail "草稿" both resolve through the same loop).
///
/// Free function (not a method on `MailController`) so it's testable without
/// spinning up the actor — same pattern as `ComposeScriptBuilder.swift`.

/// Custom AppleScript error number raised when no per-account drafts child
/// matches the requested account. `MailController.listDrafts` translates it
/// into an actionable error message (point the caller at `account_id`).
let listDraftsNoMatchErrorNumber = 9174

/// Build the `list_drafts` AppleScript, preferring `accountId` (UUID) when
/// available and falling back to `accountName` for backward compatibility.
///
/// - Parameters:
///   - accountId: Optional account UUID. When non-nil AND non-empty, children
///     are matched by `id of account of mb` — globally unique, no collision
///     or localization risk.
///   - accountName: Matched against Mail's AppleScript account `name` (the
///     account description, e.g. "Google") in the fallback path. Note this is
///     NOT necessarily the email address (#173/#176 namespace caveat).
/// - Returns: A complete AppleScript program (string), ready for
///   `MailController.runScriptAsList(...)`. Returns the matched mailbox's
///   message subjects; raises error number 9174 when no child matches.
func buildListDraftsScript(accountId: String?, accountName: String) -> String {
    let condition: String
    if let aid = accountId, !aid.isEmpty {
        condition = "(id of account of mb) is \"\(appleScriptEscape(aid))\""
    } else {
        condition = "(name of account of mb) is \"\(appleScriptEscape(accountName))\""
    }
    // Per-child try guard (verify PR #181 finding 3): a unified-drafts child
    // without a resolvable `account` property (an "On My Mac" local drafts
    // container, POP-style local storage, a disabled account) would otherwise
    // raise mid-loop and abort the whole script — breaking list_drafts for
    // unrelated, previously-working accounts depending on iteration order.
    // The guard skips such children; a genuine no-match still reaches 9174.
    return """
    tell application "Mail"
        repeat with mb in (every mailbox of drafts mailbox)
            try
                if \(condition) then
                    return subject of messages of mb
                end if
            end try
        end repeat
        error "No drafts mailbox matched the requested account" number \(listDraftsNoMatchErrorNumber)
    end tell
    """
}

/// Actionable hint for the `list_drafts` no-match case (AppleScript error
/// `listDraftsNoMatchErrorNumber` / 9174). Extracted from `MailController.listDrafts`'s
/// catch branch (#185) so the `9174 → operationFailed` translation contract is
/// unit-testable without spinning up the actor — same pure-free-function pattern as
/// `saveAttachmentAppleEventHint`, and co-located here with the 9174 constant + emitter.
///
/// Advice matches the selector that actually ran (verify PR #181 finding 18): a
/// UUID-mode failure is about a wrong/stale UUID, not the account_name namespace.
func listDraftsNoMatchHint(accountId: String?, accountName: String) -> String {
    if let aid = accountId, !aid.isEmpty {
        return "No drafts mailbox found for account_id \"\(aid)\". "
            + "Check the UUID against list_accounts — the account may have been "
            + "removed or the UUID may belong to another Mail profile."
    } else {
        return "No drafts mailbox found for account_name \"\(accountName)\". "
            + "Note: account_name must match Mail's AppleScript account name (the account "
            + "description, e.g. \"Google\"), which often differs from the email address. "
            + "Pass account_id (the UUID from list_accounts) for reliable matching."
    }
}

/// Translate a `list_drafts` AppleScript error (#185): the no-match error
/// (`listDraftsNoMatchErrorNumber` / 9174) becomes an actionable `operationFailed`
/// carrying `listDraftsNoMatchHint`; **every other error is returned unchanged** for
/// the caller to rethrow. Pure + actor-free, so the full `9174 → operationFailed`
/// code-path contract — the `code == 9174` guard, the `operationFailed` wrapping, AND
/// non-9174 propagation — is behaviorally unit-testable without a runner seam, not
/// merely the hint string.
func translateListDraftsScriptError(_ error: Error, accountId: String?, accountName: String) -> Error {
    if case let MailError.scriptFailed(_, code) = error, code == listDraftsNoMatchErrorNumber {
        return MailError.operationFailed(
            listDraftsNoMatchHint(accountId: accountId, accountName: accountName))
    }
    return error
}
