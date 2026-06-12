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
