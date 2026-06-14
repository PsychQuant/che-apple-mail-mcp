import Foundation

/// AppleScript builders for the account-level mail-check / sync action tools (#191).
///
/// `check_for_new_mail` and `synchronize_account` previously emitted a bare
/// `account "<name>"` selector, which matches Mail's account **description** — so an
/// email-form `account_name` (what `list_accounts` / the SQLite-path tools surface)
/// yielded a structural `-1728`, with no `account_id` escape hatch at all (#191,
/// surfaced by #176/PR #190 verify). These builders adopt the same `account_id`
/// overload the #104/#176 sweep applied to the 14 message tools: account selection
/// goes through `resolveAccountRef`, which emits `(account id "<UUID>")` when an
/// `accountId` is present (collision-free, #101) and `account "<name>"` otherwise.
///
/// Free functions (not methods on `MailController`) so the selector shape is unit-
/// testable without spinning up the actor — same pattern as `ListDraftsScriptBuilder`
/// / `SpecialMailboxesScriptBuilder`.
///
/// Byte-compatibility: with `accountId == nil`/empty, `resolveAccountRef` returns
/// `account "<name>"`, so the name-mode / check-all scripts are byte-identical to the
/// pre-#191 inline strings — only the new UUID-selector branch is additive.

/// Build the `check_for_new_mail` AppleScript.
///
/// - Parameters:
///   - accountId: Optional account UUID. When non-nil AND non-empty, selects via
///     `account id "<UUID>"` (takes precedence over accountName).
///   - accountName: Optional account description / email. When both this and
///     `accountId` are nil/empty → the check-all form (`check for new mail`,
///     byte-identical to pre-#191).
///
/// Note (#191 verify): an **empty-string** `accountName` is normalized to check-all
/// (empty == omitted). Pre-#191 a non-nil `""` slipped past the `if let` and emitted
/// `check for new mail for account ""` (which Mail failed to match anyway); this is a
/// deliberate normalization, not a regression. nil and non-empty inputs are byte-identical.
func buildCheckForNewMailScript(accountId: String?, accountName: String?) -> String {
    guard hasAccountSelector(accountId: accountId, accountName: accountName) else {
        // Check-all: byte-identical to the pre-#191 no-account branch.
        return """
        tell application "Mail"
            check for new mail
            return "Checking for new mail in all accounts"
        end tell
        """
    }
    let ref = resolveAccountRef(accountId: accountId, accountName: accountName ?? "")
    let label = syncCheckAccountLabel(accountId: accountId, accountName: accountName ?? "")
    return """
    tell application "Mail"
        check for new mail for \(ref)
        return "Checking for new mail in \(label)"
    end tell
    """
}

/// Build the `synchronize_account` AppleScript.
///
/// - Parameters:
///   - accountId: Optional account UUID. When non-nil AND non-empty, selects via
///     `account id "<UUID>"` (takes precedence over accountName), and may be supplied
///     ALONE (the #191-verify-R1 escape hatch — pass `accountName: ""`).
///   - accountName: Account description / email. NOT required when `accountId` is given;
///     the handler enforces "at least one of account_name / account_id".
func buildSynchronizeAccountScript(accountId: String?, accountName: String) -> String {
    let ref = resolveAccountRef(accountId: accountId, accountName: accountName)
    let label = syncCheckAccountLabel(accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        synchronize \(ref)
        return "Synchronizing account: \(label)"
    end tell
    """
}

/// The human-readable account label for the action's return message: prefer the
/// `account_name` the caller supplied (matches the pre-#191 message for the common
/// case), falling back to the UUID when only `account_id` was given. Escaped because
/// it is interpolated into an AppleScript string literal.
func syncCheckAccountLabel(accountId: String?, accountName: String) -> String {
    if !accountName.isEmpty {
        return appleScriptEscape(accountName)
    }
    if let aid = accountId, !aid.isEmpty {
        return appleScriptEscape(aid)
    }
    return "account"
}

/// Whether *any* account selector was supplied — a non-empty `accountId` OR a
/// non-empty `accountName`. The single source of truth for the "is a specific account
/// targeted?" decision shared by `buildCheckForNewMailScript` (check-all vs per-account)
/// and the `check_for_new_mail` / `synchronize_account` handlers (#191 verify R2:
/// `synchronize_account`'s "at least one selector" guard was previously inline + untested).
/// Empty strings count as absent, matching the empty-string normalization.
func hasAccountSelector(accountId: String?, accountName: String?) -> Bool {
    return !(accountId ?? "").isEmpty || !(accountName ?? "").isEmpty
}
