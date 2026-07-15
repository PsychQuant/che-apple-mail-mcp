import Foundation

/// AppleScript builder for per-account special-mailbox name resolution (#179).
///
/// `get_special_mailboxes` without an account returns the app-level **unified**
/// special-mailbox names; with an account selector it returns *that account's*
/// real (localized / provider) names — resolved by the #174 unified-children
/// reverse-lookup, generalized here from drafts (`ListDraftsScriptBuilder`)
/// across drafts/sent/trash/junk/inbox (#249 lifted the inbox deferral).
///
/// `outbox` is deliberately excluded (design D4): it is an app-level transient
/// send queue with no per-account child like the other unified special mailboxes.
///
/// Free function (not a method on `MailController`) so it's testable without
/// spinning up the actor — same pattern as `ListDraftsScriptBuilder`.

/// The special mailboxes resolved per-account, in result order. `key` is the
/// JSON key in the per-account result; `container` is the app-level unified
/// mailbox whose per-account children are enumerated.
///
/// Scope: the four `<X> mailbox` special mailboxes (drafts/sent/trash/junk —
/// #179) plus `inbox` (#249). Inbox was initially deferred because it is
/// referenced as `inbox` (not `<X> mailbox`) and its per-account child
/// semantics were unverified; the 2026-07-14 live multi-account check (#249,
/// the deferral condition #179's spec set) confirmed `every mailbox of inbox`
/// exposes per-account children on all 7 configured accounts — including a
/// LOCALIZED real name on an Exchange account (收件匣), proving the
/// resolution carries real value. Appended last so the n0…n3 positions of
/// the original four stay stable.
let perAccountSpecialMailboxes: [(key: String, container: String)] = [
    ("drafts", "drafts mailbox"),
    ("sent", "sent mailbox"),
    ("trash", "trash mailbox"),
    ("junk", "junk mailbox"),
    ("inbox", "inbox"),
]

/// Build the per-account special-mailbox-name AppleScript.
///
/// The script first locates the account directly (over `accounts`) to capture its
/// **canonical** `id` + `name` and a **match count** — this is what distinguishes
/// "no such account" (→ actionable error) from "account exists but has no child for
/// a special type" (→ omit that key), and detects a description-name collision
/// (count > 1) symmetric to the email→UUID ambiguity throw (#101/#176). It then
/// enumerates each unified container's per-account children for the localized names.
///
/// - Parameters:
///   - accountId: Optional account UUID. When non-nil AND non-empty, matching is by
///     `id` (globally unique, no collision) — takes precedence over accountName.
///   - accountName: Matched against `name of account` (Mail's account description)
///     in the fallback path; NOT necessarily the email (#173/#176).
/// - Returns: a complete AppleScript returning ONE list:
///   `{matchedId, matchedName, matchCount, n0…n4, p0…p4}` where `n0…n4` are the
///   matched child's leaf names parallel to `perAccountSpecialMailboxes`
///   (`""` = no such child), and `p0…p4` (#268) are the corresponding FULL mailbox
///   paths (`[Gmail]/草稿`, container-walk-joined to match `MailboxURL.mailboxPath` /
///   `search_emails`'s `mailbox`; `""` = absent or walk failed). Paths are appended
///   AFTER all names so the n0…n4 positions stay stable. Both the account-finding
///   loop and each container enumeration are `try`-guarded, and each path walk has
///   its own `try`, so an account-less child, an absent unified container, or a
///   failed walk is non-fatal (design D3). Parse with `resolveSpecialMailboxesResult`.
func buildSpecialMailboxNamesScript(accountId: String?, accountName: String) -> String {
    let accountCond: String   // on `acc`
    let childCond: String      // on `mb`
    if let aid = accountId, !aid.isEmpty {
        let e = appleScriptEscape(aid)
        accountCond = "(id of acc) is \"\(e)\""
        childCond = "(id of account of mb) is \"\(e)\""
    } else {
        let e = appleScriptEscape(accountName)
        accountCond = "(name of acc) is \"\(e)\""
        childCond = "(name of account of mb) is \"\(e)\""
    }
    var blocks: [String] = []
    for (idx, special) in perAccountSpecialMailboxes.enumerated() {
        // Container-level try (logic/DA finding): an absent/erroring unified
        // container (e.g. no app-level junk mailbox) must not abort the whole
        // script — n<idx> stays "" → omitted key (D3). Per-child try skips an
        // account-less On-My-Mac/local child (verify PR #181 finding 3).
        //
        // The name read is load-bearing for the fixed-tuple contract (#179 verify
        // R4/R5, findings 11 + 9): runScriptAsList drops any element whose
        // NSAppleEventDescriptor.stringValue is nil. An empty *text* yields "" (kept),
        // but a `missing value` name (a transiently nameless/proxy mailbox) yields nil
        // → it would be dropped, shifting every later position left and silently
        // misattributing names. We guard `is not missing value` BEFORE the
        // `(mbName as string)` coercion: a real name is coerced to text (never dropped);
        // a `missing value` name leaves n<idx> as "" → omitted key (D3-consistent),
        // rather than coercing into the literal text "missing value" (the R4-only
        // coercion's leak, R5 finding 9). Matches the `(id of acc as string)` /
        // `(matchCount as string)` discipline below.
        // #268: alongside the leaf name n<idx>, build the FULL mailbox path p<idx>
        // by walking `container of mb` up to (not including) the account, joining
        // parent names with "/" — reproducing MailboxURL.mailboxPath ("[Gmail]/草稿").
        // The walk is in its OWN try so a failure leaves p<idx> "" (→ omitted key)
        // WITHOUT losing the already-read leaf name (set before the walk). The stop
        // condition is `class of par is mailbox`: a top-level mailbox's container is
        // the account (not a mailbox) → loop body never runs → path == leaf.
        blocks.append("""
            set n\(idx) to ""
            set p\(idx) to ""
            try
                repeat with mb in (every mailbox of \(special.container))
                    try
                        if \(childCond) then
                            set mbName to name of mb
                            if mbName is not missing value then
                                set n\(idx) to (mbName as string)
                                try
                                    set fullPath to (mbName as string)
                                    set par to container of mb
                                    repeat while (class of par) is mailbox
                                        set parName to name of par
                                        if parName is missing value then exit repeat
                                        set fullPath to (parName as string) & "/" & fullPath
                                        set par to container of par
                                    end repeat
                                    set p\(idx) to fullPath
                                end try
                            end if
                            exit repeat
                        end if
                    end try
                end repeat
            end try
        """)
    }
    // #268: leaf names first (stable n0…n(N-1) positions — the #179 fixed-tuple
    // discipline), then the parallel full paths p0…p(N-1) appended after them.
    let names = (0..<perAccountSpecialMailboxes.count).map { "n\($0)" }.joined(separator: ", ")
    let paths = (0..<perAccountSpecialMailboxes.count).map { "p\($0)" }.joined(separator: ", ")
    return """
    tell application "Mail"
        set matchedId to ""
        set matchedName to ""
        set matchCount to 0
        repeat with acc in accounts
            try
                if \(accountCond) then
                    set matchCount to matchCount + 1
                    if matchedId is "" then
                        set matchedId to (id of acc as string)
                        set matchedName to (name of acc as string)
                    end if
                end if
            end try
        end repeat
    \(blocks.joined(separator: "\n"))
        return {matchedId, matchedName, (matchCount as string), \(names), \(paths)}
    end tell
    """
}

/// Outcome of resolving a per-account `get_special_mailboxes` query — pure,
/// actor-free, so the result contract is unit-testable without running AppleScript.
enum SpecialMailboxesResolution: Equatable {
    /// Account matched: canonical `account_id` / `account_name` + the present
    /// special-mailbox real names (absent types omitted).
    case resolved([String: String])
    /// The selector matched no account at all → caller throws the actionable hint.
    case noMatch
    /// The selector (a colliding description name) matched multiple accounts →
    /// caller throws an ambiguity error directing to `account_id`.
    case ambiguous(Int)
}

/// Parse `buildSpecialMailboxNamesScript`'s result list
/// `[matchedId, matchedName, matchCount, n0…n4]`.
///
/// - `matchedId` empty → `.noMatch` (no such account — distinct from an account
///   that merely lacks some special children).
/// - `matchCount > 1` → `.ambiguous` (description-name collision).
/// - otherwise `.resolved` with `account_id` / `account_name` (canonical, from the
///   matched account — NOT the raw caller input) plus each non-empty special name.
func resolveSpecialMailboxesResult(_ raw: [String]) -> SpecialMailboxesResolution {
    guard raw.count >= 3 else { return .noMatch }
    let matchedId = raw[0]
    let matchedName = raw[1]
    let matchCount = Int(raw[2]) ?? 0
    // matchCount is the authoritative match signal (#179 verify R4, finding 4): no
    // account matched ⇒ count 0. matchedId.isEmpty is kept as belt-and-suspenders so
    // a (Mail-impossible) account with an empty `id` can never resolve to a dict with
    // an empty account_id — it degrades to an actionable no-match instead.
    if matchCount == 0 || matchedId.isEmpty { return .noMatch }
    if matchCount > 1 { return .ambiguous(matchCount) }
    var obj: [String: String] = ["account_id": matchedId, "account_name": matchedName]
    // Tuple after the 3-element metadata header: the N leaf real names, then
    // (#268) the N full mailbox paths appended in the SAME order —
    // `[n0…n(N-1), p0…p(N-1)]`. The full path (`[Gmail]/草稿`) reproduces
    // `search_emails`'s `mailbox` field so a consumer can compare full-path ==
    // full-path directly instead of the #109 leaf-suffix heuristic. Purely
    // additive: an old-shape result carrying only names leaves `paths` empty →
    // no `_path` keys (back-compat); a per-mailbox container-walk failure yields
    // an empty path slot → that `_path` key is omitted (leaf `<key>` still set).
    let count = perAccountSpecialMailboxes.count
    let rest = Array(raw.dropFirst(3))
    let names = Array(rest.prefix(count))
    let paths = Array(rest.dropFirst(count))
    for (idx, special) in perAccountSpecialMailboxes.enumerated() {
        if idx < names.count, !names[idx].isEmpty { obj[special.key] = names[idx] }              // leaf real name (D3: omit absent)
        if idx < paths.count, !paths[idx].isEmpty { obj[special.key + "_path"] = paths[idx] }     // #268 full path (omit absent)
    }
    return .resolved(obj)
}

/// Actionable hint for the per-account `get_special_mailboxes` no-match case (#179).
///
/// Selector-aware, keyed on **`accountName` first** (verify R3 devils-advocate): the
/// handler resolves an email-form `account_name` to a UUID *before* matching, so by
/// the time a no-match surfaces, `accountId` may hold a UUID the user never typed.
/// Preferring `accountName` when present means the hint references what the caller
/// actually supplied (their email/description + the namespace advice they need); the
/// `accountId` branch is for callers who supplied a UUID directly (no account_name).
func specialMailboxesNoMatchHint(accountId: String?, accountName: String) -> String {
    if !accountName.isEmpty {
        return "No account matched account_name \"\(accountName)\". "
            + "Note: account_name must match Mail's AppleScript account name (the account "
            + "description, e.g. \"Google\"), which often differs from the email address. "
            + "Pass account_id (the UUID from list_accounts) for reliable matching."
    } else if let aid = accountId, !aid.isEmpty {
        return "No account matched account_id \"\(aid)\". "
            + "Check the UUID against list_accounts — the account may have been "
            + "removed or the UUID may belong to another Mail profile."
    } else {
        return "No account matched the supplied selector. Use list_accounts to find a valid account_id."
    }
}

/// Actionable hint for the per-account `get_special_mailboxes` ambiguity case (#179):
/// a description `account_name` matched multiple Mail accounts (the #101 collision).
/// Ambiguity only arises in name mode — a UUID is globally unique.
func specialMailboxesAmbiguityHint(count: Int, accountName: String) -> String {
    return "account_name \"\(accountName)\" matches \(count) Mail accounts. "
        + "Pass account_id (the UUID from list_accounts) to select one."
}

/// Decide which `accountName` the no-match / ambiguity hint should name, so the hint
/// references the selector the builder actually matched on (#179 verify R4, findings
/// 2 & 5 — the gap all four lens reviewers missed).
///
/// The builder matches on `account_id` whenever it is non-empty — which includes an
/// email-form `account_name` the handler laundered into a UUID. The hint therefore
/// can't naively prefer `account_name`:
/// - **Explicit `account_id` supplied** (`explicitAccountId == true`) → the builder
///   matched on that UUID, NOT on any co-supplied `account_name`. Return `""` so the
///   hint takes the `account_id` branch and blames the UUID actually used — never a
///   co-supplied name that may well exist (the `{account_id: BAD, account_name: Google}`
///   trap, which the schema actively invites by telling callers to pass both).
/// - **No explicit `account_id`** → the user supplied only `account_name` (an email
///   laundered to a UUID, or a description matched by name). Return `account_name` so
///   the hint references what the user actually typed (preserving the email→UUID
///   non-laundering fix from verify R3).
///
/// Matching is unaffected: in the explicit-`account_id` case `account_id` is non-empty
/// so the builder never consults `account_name` for matching anyway — only the hint
/// wording changes.
func specialMailboxesHintAccountName(explicitAccountId: Bool, accountName: String?) -> String {
    return explicitAccountId ? "" : (accountName ?? "")
}

/// Map a `SpecialMailboxesResolution` to the per-account result dictionary, or
/// throw the actionable error (#179). Pure + actor-free so the `.noMatch →
/// operationFailed` and `.ambiguous → invalidParameter` code-path mappings are
/// unit-testable without the actor — the #185 discipline applied to this tool.
func specialMailboxesResultOrThrow(_ resolution: SpecialMailboxesResolution,
                                   accountId: String?, accountName: String) throws -> [String: String] {
    switch resolution {
    case .resolved(let obj):
        return obj
    case .noMatch:
        throw MailError.operationFailed(specialMailboxesNoMatchHint(accountId: accountId, accountName: accountName))
    case .ambiguous(let count):
        throw MailError.invalidParameter(specialMailboxesAmbiguityHint(count: count, accountName: accountName))
    }
}
