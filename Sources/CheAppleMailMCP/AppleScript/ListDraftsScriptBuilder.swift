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
    // The guard wraps ONLY the condition eval (matched-flag form, #276): a
    // real error while fetching the matched child's rows must propagate, not
    // be swallowed into a misleading 9174.
    //
    // Row payload (#276, draft-update spec; verify R2, Codex): each row's id
    // and subject are read from the SAME message reference (one snapshot,
    // per-message loop) — two bulk parallel-list queries could mis-pair when
    // the mailbox mutates between them with unchanged length, the only shape
    // the parser's mismatch guard cannot catch, and a mis-paired row would
    // let subject_match delete the wrong id. Rows are RS-joined (ASCII 30,
    // comma-safe) and the id/subject groups GS-separated (ASCII 29). A
    // reference dying mid-loop aborts the script (fail closed). Parsed by
    // `parseDraftRows`.
    return """
    tell application "Mail"
        repeat with mb in (every mailbox of drafts mailbox)
            set matched to false
            try
                if \(condition) then set matched to true
            end try
            if matched then
                set idStr to ""
                set subjStr to ""
                set firstRow to true
                repeat with dm in (every message of mb)
                    set dmId to (id of dm) as string
                    set dmSubj to (subject of dm) as string
                    if firstRow then
                        set firstRow to false
                        set idStr to dmId
                        set subjStr to dmSubj
                    else
                        set idStr to idStr & (ASCII character 30) & dmId
                        set subjStr to subjStr & (ASCII character 30) & dmSubj
                    end if
                end repeat
                return idStr & (ASCII character 29) & subjStr
            end if
        end repeat
        error "No drafts mailbox matched the requested account" number \(listDraftsNoMatchErrorNumber)
    end tell
    """
}

/// #276 — unified variant for `update_draft`'s account-omitted path: scan
/// EVERY drafts child (all accounts) and aggregate the id/subject groups.
/// No per-account condition and no 9174 (there is no "requested account" to
/// miss).
///
/// FAIL CLOSED (verify R1, Codex): in all-accounts mode every child
/// participates in the uniqueness verdict — a swallowed per-child error
/// could hide a real cross-account ambiguity and let `update_draft` treat a
/// partial view as a unique match (wrong deletion). So there is deliberately
/// NO try here: any child error aborts the whole scan, the locate step
/// fails, and `update_draft` refuses — never deletes on partial knowledge.
func buildListAllDraftsScript() -> String {
    return """
    tell application "Mail"
        set idStr to ""
        set subjStr to ""
        set firstRow to true
        repeat with mb in (every mailbox of drafts mailbox)
            repeat with dm in (every message of mb)
                set dmId to (id of dm) as string
                set dmSubj to (subject of dm) as string
                if firstRow then
                    set firstRow to false
                    set idStr to dmId
                    set subjStr to dmSubj
                else
                    set idStr to idStr & (ASCII character 30) & dmId
                    set subjStr to subjStr & (ASCII character 30) & dmSubj
                end if
            end repeat
        end repeat
        return idStr & (ASCII character 29) & subjStr
    end tell
    """
}

/// Custom AppleScript error number raised when `update_draft`'s delete step
/// finds no draft with the located id (raced away between locate and delete).
let updateDraftDeleteNotFoundErrorNumber = 9276

/// #276 — delete a draft BY ID + EXACT SUBJECT inside the unified-drafts
/// children. Deleting here (instead of `delete_email`) avoids resolving the
/// per-account drafts mailbox NAME entirely — the same #174 mechanism that
/// located the draft also scopes the deletion.
///
/// The predicate conjoins id AND exact subject (verify R3, DA-1): an
/// unscoped bare-id sweep would bet on Mail message ids being GLOBALLY
/// unique — with the subject conjunct, a cross-account id collision with a
/// different subject is protected, and a same-id-same-subject collision
/// would already have refused as ambiguous at locate time. #221-safe (id +
/// subject equality, never content); AppleScript `delete` moves to Trash
/// (recoverable), not a permanent expunge.
func buildDeleteDraftByIdScript(draftId: String, subject: String, accountId: String?, accountName: String?) -> String {
    // Contract (verify R1, security LOW): draftId must already be validated
    // as ASCII digits by the caller — it is interpolated as an AppleScript
    // numeric literal. The assert catches contract violations in debug.
    assert(!draftId.isEmpty && draftId.allSatisfy { ("0"..."9").contains($0) },
           "buildDeleteDraftByIdScript requires a pre-validated ASCII-numeric draftId")
    let conditionLine: String
    if let aid = accountId, !aid.isEmpty {
        conditionLine = """
                try
                    if (id of account of mb) is "\(appleScriptEscape(aid))" then set matched to true
                end try
        """
    } else if let an = accountName, !an.isEmpty {
        conditionLine = """
                try
                    if (name of account of mb) is "\(appleScriptEscape(an))" then set matched to true
                end try
        """
    } else {
        conditionLine = "        set matched to true"
    }
    return """
    tell application "Mail"
        repeat with mb in (every mailbox of drafts mailbox)
            set matched to false
    \(conditionLine)
            if matched then
                set target to missing value
                try
                    set target to (first message of mb whose id is \(draftId) and subject is "\(appleScriptEscape(subject))")
                end try
                if target is not missing value then
                    delete target
                    return "Draft deleted"
                end if
            end if
        end repeat
        error "No draft with id \(draftId) found in the drafts mailboxes" number \(updateDraftDeleteNotFoundErrorNumber)
    end tell
    """
}

/// #276 — parse the GS/RS-delimited id+subject payload emitted by
/// `buildListDraftsScript` / `buildListAllDraftsScript` into paired rows.
/// Pure + actor-free (unit-testable). A length mismatch between the two
/// groups throws — never silently truncate a zip (a mis-paired row could
/// direct `update_draft` at the wrong draft).
func parseDraftRows(_ raw: String) throws -> [(id: String, subject: String)] {
    let GS = "\u{001D}", RS = "\u{001E}"
    let groups = raw.components(separatedBy: GS)
    guard groups.count == 2 else {
        throw MailError.operationFailed(
            "list_drafts: unexpected script result shape (expected id/subject groups)")
    }
    // Zero drafts: both groups empty. Do NOT shortcut per-group emptiness —
    // a single draft with an EMPTY subject yields ids=["N"], subjects=[""]
    // and must still pair (see tests).
    if groups[0].isEmpty && groups[1].isEmpty { return [] }
    let ids = groups[0].components(separatedBy: RS)
    let subjects = groups[1].components(separatedBy: RS)
    guard ids.count == subjects.count else {
        throw MailError.operationFailed(
            "list_drafts: id/subject list length mismatch (\(ids.count) vs \(subjects.count)) — refusing to zip")
    }
    // Verify R1 (Codex): every id must be a non-empty ASCII-numeric Mail
    // rowid — an empty or non-numeric id violates the list_drafts contract
    // and could otherwise flow into the delete script. Throw, never emit.
    for id in ids where id.isEmpty || !(id.allSatisfy { ("0"..."9").contains($0) }) {
        throw MailError.operationFailed(
            "list_drafts: malformed draft id '\(id)' in script payload — refusing")
    }
    return zip(ids, subjects).map { (id: $0.0, subject: $0.1) }
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
