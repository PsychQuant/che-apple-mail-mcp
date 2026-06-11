import Foundation

/// Shared AppleScript reference builders for account-UUID disambiguation
/// (the multi-account-same-display_name defect, #101 / #104 sweep).
///
/// `account id "..."` AppleScript syntax was verified empirically on
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
/// Both error modes match the legacy `account "<display_name>"` path's
/// error codes (`-1719` / `-1728`), so `MailController.runScript` error
/// handling continues to apply unchanged.
///
/// The `resolveMsgRef` / `resolveMailboxRef` functions are the **single
/// chokepoint** every AppleScript-routed tool calls — when `accountId` is
/// supplied they use the globally-unique UUID selector; when nil/empty they
/// fall back to the legacy display_name form, byte-identical to the
/// pre-sweep `MailController.msgRef` / `mailboxRef` output.
///
/// Free functions (not methods on `MailController`) so they're testable
/// without spinning up the actor — same pattern as `ComposeScriptBuilder.swift`.

// MARK: - Nested mailbox chain (#174)

/// Rewrite a slash-containing mailbox path into an AppleScript container
/// chain. MailSQLite emits mailbox names in on-disk path form
/// (`[Gmail]/全部郵件`), but Mail's AppleScript `name` property holds only
/// the LEAF name — `whose name is "<full path>"` can never match a nested
/// mailbox and fails with -1719 (#174). Empirically verified (2026-06-11):
/// `mailbox "草稿" of mailbox "[Gmail]" of (account id "...")` resolves.
///
/// Only applied when the path splits into ≥ 2 non-empty segments; degenerate
/// inputs (no "/", "/" alone, consecutive-slash collapse to one segment)
/// keep the legacy `whose name is` form so non-nested callers stay
/// byte-identical (#104 regression guard). "/" is always a hierarchy
/// separator in MailSQLite output (it derives from on-disk .mbox nesting),
/// so the rewrite never misfires for that caller; hand-crafted names that
/// merely contain a literal "/" failed with -1719 before and keep the same
/// failure surface.
///
/// - Returns: `(mailbox "leaf" of mailbox "parent" ... of <accountRef>)`,
///   or nil when fewer than 2 non-empty segments remain.
func nestedMailboxChain(path: String, accountRef: String) -> String? {
    let segments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    guard segments.count >= 2 else { return nil }
    let chain = segments.reversed()
        .map { "mailbox \"\(appleScriptEscape($0))\"" }
        .joined(separator: " of ")
    return "(\(chain) of \(accountRef))"
}

// MARK: - UUID-form builders

/// Build an AppleScript reference to a mailbox using the account's globally
/// unique UUID. Avoids the display_name ambiguity that plagues
/// `account "<display_name>"` selectors when multiple accounts share the
/// same display name.
///
/// #137 refactor: composes `resolveAccountRef` instead of inlining the
/// account-selector syntax. Three places (this, `resolveMailboxRef`, and the
/// `resolveAccountRef` definition itself) previously knew how to build the
/// account selector — drift risk if `(account id "...")` syntax ever needs
/// hardening. Now there is exactly one definition.
///
/// - Parameters:
///   - mailbox: Mailbox name (e.g. "INBOX", "[Gmail]/全部郵件"). Escaped via `appleScriptEscape`.
///   - accountId: Account UUID. Caller must ensure non-empty — use
///     `resolveMailboxRef` for nil/empty handling.
/// - Returns: `(first mailbox of (account id "<escaped UUID>") whose name is "<escaped mailbox>")`
func mailboxRefByAccountId(_ mailbox: String, accountId: String) -> String {
    // accountName: "" is intentional — accountId is guaranteed non-empty by
    // contract, so resolveAccountRef takes the UUID path and never consults
    // accountName. Passing a sentinel "" surfaces any future regression
    // (caller bypassing the contract) as a visibly wrong fallback rather
    // than silently using a "real" name.
    let accountRef = resolveAccountRef(accountId: accountId, accountName: "")
    if let chain = nestedMailboxChain(path: mailbox, accountRef: accountRef) {
        return chain
    }
    return "(first mailbox of \(accountRef) whose name is \"\(appleScriptEscape(mailbox))\")"
}

/// Build an AppleScript reference to a message by ROWID, using account UUID
/// for disambiguation. See `mailboxRefByAccountId` for the syntax rationale.
///
/// - Note: Apple Mail's `id` of a message is a numeric internal identifier
///   (not the RFC 822 Message-ID string), so `whose id is <N>` is
///   interpolated unquoted. A release-safe numeric guard (#118) rejects
///   non-numeric `id`; Server-layer `requireMessageId` is the user-facing
///   contract.
func msgRefByAccountId(_ id: String, mailbox: String, accountId: String) -> String {
    // Release-safe guard (#118): `id` is interpolated unquoted into `whose id is`.
    // A debug-only `assert` compiles out under `-O`, so a caller bypassing
    // `Server.requireMessageId` could inject an AppleScript predicate. `Int(id)`
    // succeeds only for `[+-]?\d+` — on failure substitute an impossible id so the
    // malicious string is never interpolated; the script fails cleanly with -1728.
    let safeId = Int(id) != nil ? id : "-1"
    return "(first message of \(mailboxRefByAccountId(mailbox, accountId: accountId)) whose id is \(safeId))"
}

// MARK: - Resolvers (UUID path with display_name fallback)

/// Resolve a mailbox AppleScript reference, preferring the account UUID
/// when available and falling back to the legacy display_name form.
///
/// - Parameters:
///   - mailbox: Mailbox name.
///   - accountId: Optional account UUID. Non-nil AND non-empty → UUID path.
///   - accountName: Display name. Used only in the fallback path.
/// - Returns: `(first mailbox of (account id "...") whose name is "...")`
///   when `accountId` is usable, else `(first mailbox of account "<display_name>" whose name is "...")`
///   — the latter byte-identical to `MailController.mailboxRef`.
func resolveMailboxRef(mailbox: String, accountId: String?, accountName: String) -> String {
    // #137 refactor: compose `resolveAccountRef` to keep account-selector
    // syntax (UUID vs display_name) defined in exactly one place. Pre-#137
    // both branches inlined the selector — drift risk if syntax/escaping
    // ever needs hardening.
    let accountRef = resolveAccountRef(accountId: accountId, accountName: accountName)
    // #174: slash-containing names are on-disk nested paths — address them
    // through the container chain; single-segment names keep the legacy
    // whose-name-is form byte-identical.
    if let chain = nestedMailboxChain(path: mailbox, accountRef: accountRef) {
        return chain
    }
    return "(first mailbox of \(accountRef) whose name is \"\(appleScriptEscape(mailbox))\")"
}

/// Resolve a message AppleScript reference (by ROWID), preferring the
/// account UUID when available and falling back to the legacy display_name
/// form. See `resolveMailboxRef` for the fallback rationale.
///
/// - Returns: byte-identical to `MailController.msgRef` when `accountId`
///   is nil/empty.
func resolveMsgRef(id: String, mailbox: String, accountId: String?, accountName: String) -> String {
    if let aid = accountId, !aid.isEmpty {
        return msgRefByAccountId(id, mailbox: mailbox, accountId: aid)
    }
    // Release-safe guard (#118) — see msgRefByAccountId for the rationale.
    let safeId = Int(id) != nil ? id : "-1"
    return "(first message of \(resolveMailboxRef(mailbox: mailbox, accountId: nil, accountName: accountName)) whose id is \(safeId))"
}

/// Resolve an **account-only** AppleScript selector — just the account, not a
/// mailbox or message reference. Needed by tools that address an account
/// directly (`create_mailbox`: `make new mailbox ... at <accountRef>`) rather
/// than referencing an existing mail item (#104 PR-D).
///
/// - Parameters:
///   - accountId: Optional account UUID. Non-nil AND non-empty → UUID path.
///   - accountName: Display name. Used only in the fallback path.
/// - Returns: `(account id "<escaped UUID>")` when `accountId` is usable,
///   else `account "<escaped display_name>"` — the latter byte-identical to
///   the legacy `account "<display_name>"` selector used by
///   `MailController.createMailbox` before the sweep.
func resolveAccountRef(accountId: String?, accountName: String) -> String {
    if let aid = accountId, !aid.isEmpty {
        return "(account id \"\(appleScriptEscape(aid))\")"
    }
    return "account \"\(appleScriptEscape(accountName))\""
}
