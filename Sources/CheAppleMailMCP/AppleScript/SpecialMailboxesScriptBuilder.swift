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
        // #315: the #268 container walk that used to live here is GONE — it was
        // structurally unable to work. References enumerated from the app-level
        // unified container have a non-mailbox `container` on the first probe,
        // so `repeat while (class of par) is mailbox` never ran and the walk
        // succeeded VACUOUSLY: it emitted the leaf as the "full path" for
        // genuinely nested mailboxes (4/5 types wrong on all 7 live accounts),
        // and neither documented fail-safe fired because nothing ever failed.
        // The script now identifies LEAVES only; the full path is joined from
        // the Envelope Index (`joinSpecialMailboxPath`) in the controller —
        // the source that was correct all along (`MailboxURL.mailboxPath`).
        blocks.append("""
            set n\(idx) to ""
            try
                repeat with mb in (every mailbox of \(special.container))
                    try
                        if \(childCond) then
                            set mbName to name of mb
                            if mbName is not missing value then
                                set n\(idx) to (mbName as string)
                            end if
                            exit repeat
                        end if
                    end try
                end repeat
            end try
        """)
    }
    // Leaf names in stable n0…n(N-1) positions (the #179 fixed-tuple
    // discipline). No p0…p(N-1) any more (#315): paths come from the index.
    let names = (0..<perAccountSpecialMailboxes.count).map { "n\($0)" }.joined(separator: ", ")
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
        return {matchedId, matchedName, (matchCount as string), \(names)}
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
/// #315 — join an AppleScript-identified special-mailbox LEAF against the
/// account's Envelope-Index mailbox paths to obtain the full path.
///
/// Replaces the #268 container walk, which was structurally unable to work:
/// references enumerated from the app-level unified container have a
/// non-mailbox `container` on the first probe, so the walk succeeded
/// vacuously and emitted the leaf as the "full path" for genuinely nested
/// mailboxes — a wrong value indistinguishable from a correct top-level
/// result (4/5 types wrong on all 7 live accounts, #315). The Envelope Index
/// already holds the true path (`MailboxURL.mailboxPath` — the same
/// representation `search_emails` returns), so ask the source that works.
///
/// Honest by construction:
/// - exactly one candidate whose path IS the leaf or ENDS in "/leaf" → that path
/// - zero candidates (no index / EWS / leaf unknown) → nil → `_path` omitted
/// - two or more candidates (ambiguous leaf) → nil — never guess; the consumer
///   falls back to leaf comparison, which is the observable signal #268's
///   fail-safe promised but never delivered
///
/// #345 — this single-leaf form is UNCORROBORATED: a lone nested candidate is
/// not proof of identity. The server calls `joinSpecialMailboxPaths` instead.
/// Kept as the candidate-selection building block and for the cases where leaf
/// uniqueness genuinely is decisive.
func joinSpecialMailboxPath(leaf: String, mailboxPaths: [String]) -> String? {
    guard !leaf.isEmpty else { return nil }
    let candidates = mailboxPaths.filter { $0 == leaf || $0.hasSuffix("/" + leaf) }
    return candidates.count == 1 ? candidates[0] : nil
}

/// #345 — resolve ALL of an account's special-mailbox leaves together, so a
/// nested candidate can be corroborated before it is believed.
///
/// The defect this closes: "exactly one candidate" was decided purely by string
/// shape. With the real Drafts mailbox missing from the index (fresh account,
/// lagging sync) and an ordinary `Projects/Drafts` folder present, that folder
/// won uncontested and was returned as `drafts_path` — a value
/// wire-indistinguishable from a correct one, with #315's omission fail-safe
/// never firing because nothing had failed.
///
/// Neither remedy the issue proposed is available:
/// - "omit when the only candidate is nested" would break Gmail, whose real
///   drafts mailbox IS `[Gmail]/草稿` — the most common configuration there is.
/// - "cross-check against the index's role data" — there is none. Per
///   `.claude/rules/r-must-direct-db.md` the `mailboxes` table carries only
///   `url / total_count / unread_count`; special-mailbox role is app-level
///   metadata that exists in AppleScript's object model and nowhere else.
///
/// So corroboration comes from data already in hand. A genuine provider
/// container holds SEVERAL special mailboxes — `[Gmail]` is the parent of
/// drafts, sent, junk and trash — while an ordinary folder that happens to
/// share one leaf name is the parent of exactly one. Convergence is the signal:
///
/// - exact top-level match (`path == leaf`) → accepted outright
/// - a single nested candidate → accepted only if ≥1 OTHER special leaf also
///   resolves to a single candidate under the SAME parent
/// - zero candidates, or an ambiguous leaf → omitted, exactly as in #315
///
/// Conservative on purpose: an account whose ONLY indexed special mailbox is
/// nested gets an omitted `_path`. The leaf is still returned, and omission is
/// the documented, observable contract — whereas a confident wrong path is the
/// failure #268 and #315 were both about.
///
/// Residue: two ordinary folders under one parent that happen to carry two
/// special leaf names (`Projects/Drafts` + `Projects/Sent`, with the real ones
/// absent) would corroborate each other. Strictly more contrived than the
/// reported case, and no data available here distinguishes it.
func joinSpecialMailboxPaths(
    leaves: [(key: String, leaf: String)],
    mailboxes: [(path: String, components: [String])]
) -> [String: String] {
    // Parent key from COMPONENTS, never from the joined string (#345 verify):
    // `MailboxURL.mailboxPath` decodes `%2F` inside a name into a `/`, so two
    // unrelated TOP-LEVEL mailboxes named `Projects/Drafts` and `Projects/Sent`
    // would appear to share a parent and corroborate each other. NUL-joined
    // because no mailbox name can contain it.
    func parentKey(_ components: [String]) -> String {
        components.dropLast().joined(separator: "\u{0}")
    }

    var accepted: [String: String] = [:]
    var pending: [(key: String, candidates: [(path: String, parent: String)])] = []

    for entry in leaves where !entry.leaf.isEmpty {
        // A leaf that is ALREADY a multi-component path needs no join —
        // AppleScript handed us the whole thing, so nothing is inferred (#315).
        // Restricted to `components.count > 1` on purpose: a top-level name
        // trivially equals its own path, so without that guard this shortcut
        // silently reinstates "accept any unique top-level match", which is the
        // positional acceptance this issue exists to remove.
        if let exact = mailboxes.first(where: { $0.path == entry.leaf && $0.components.count > 1 }) {
            accepted[entry.key] = exact.path
            continue
        }
        let candidates = mailboxes.filter { $0.components.last == entry.leaf }
        guard !candidates.isEmpty else { continue }

        // RFC 3501 §5.1: INBOX is the one special mailbox the spec pins, and it
        // lives at the path root. That is a rule, not a guess about position.
        if entry.leaf.compare("INBOX", options: .caseInsensitive) == .orderedSame,
           let root = candidates.first(where: { $0.components.count == 1 }) {
            accepted[entry.key] = root.path
            continue
        }
        pending.append((entry.key, candidates.map { ($0.path, parentKey($0.components)) }))
    }

    // Which containers hold SEVERAL special mailboxes. Only unambiguous
    // resolutions vote — an entry that is itself undecided cannot be evidence —
    // and votes are counted per DISTINCT PATH (#345 verify): two roles that
    // report the same leaf would otherwise let one folder corroborate itself.
    var pathsByParent: [String: Set<String>] = [:]
    for item in pending where item.candidates.count == 1 {
        let only = item.candidates[0]
        pathsByParent[only.parent, default: []].insert(only.path)
    }

    for item in pending {
        let corroborated = item.candidates.filter { (pathsByParent[$0.parent]?.count ?? 0) >= 2 }
        // Exactly one supported reading resolves the entry; zero or several
        // omit, as #315 did. Position is never the tiebreak — "prefer the
        // top-level candidate" would pick a user folder named 垃圾桶 over the
        // real `[Gmail]/垃圾桶`, which is the same class of confident-wrong
        // answer this issue exists to remove. The root is just another
        // container: several specials sitting at it corroborate each other.
        if corroborated.count == 1 { accepted[item.key] = corroborated[0].path }
    }
    return accepted
}

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
