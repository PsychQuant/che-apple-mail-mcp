import Foundation
import MailSQLite

/// AppleScript builder fragments for the `search_emails` AppleScript **fallback**
/// (#194). The SQLite primary path honors `field` / `date_from` / `date_to`; this
/// makes the fallback honor the same contract instead of silently dropping them.
///
/// Free functions (not methods on `MailController`) so they're unit-testable
/// without spinning up the actor — same pattern as `SpecialMailboxesScriptBuilder`
/// / `ListDraftsScriptBuilder`. `MailController.searchEmails` assembles these
/// fragments into each of its three structural branches (specific mailbox /
/// account-only / all-accounts).
///
/// Parity reference — what each `field` means in the SQLite path
/// (`EnvelopeIndexReader.swift`): `subject` → subject LIKE; `sender` → address or
/// display-name LIKE; `recipient` → any recipient address or name LIKE; `any` →
/// subject or sender or recipient; dates → `date_received >= from AND <= to`
/// (inclusive both ends).
///
/// **Design (B1 + C2, #194):** `subject`/`sender`/`any` use the fast `whose`
/// substring predicate (so the default `any` search stays fast). `recipient` has
/// no reliable `whose` form — recipient props are object lists, and `whose … contains`
/// over a list is element-equality, not substring — so it is filtered **in-loop**
/// via `searchEmailsRecipientMatchBlock`. `any` keeps subject+sender coverage in
/// the fallback (the documented narrow residual: recipient-only matches are missed
/// under the rare fallback only; `MailController` emits a stderr note).

/// The `whose` substring predicate for the fast-path fields. Returns `nil` for
/// `.recipient` (no reliable `whose` form → caller filters in-loop). The
/// `escapedQuery` must already be `appleScriptEscape`-d by the caller.
func searchEmailsFieldPredicate(field: SearchField, escapedQuery: String) -> String? {
    switch field {
    case .subject:
        return "subject contains \"\(escapedQuery)\""
    case .sender:
        return "sender contains \"\(escapedQuery)\""
    case .any:
        // Byte-identical to the pre-#194 hardcoded predicate (regression-pinned).
        return "subject contains \"\(escapedQuery)\" or sender contains \"\(escapedQuery)\""
    case .recipient:
        return nil
    }
}

/// In-loop AppleScript that sets `_matched` (Boolean) by scanning a message's
/// `to recipients` + `cc recipients` (`address` and `name`) for the query.
/// References the loop variable `msg` (matching the `repeat with msg in foundMsgs`
/// loops in `MailController`). Each access is `try`-guarded so a `missing value`
/// address/name on one recipient cannot abort the whole search.
func searchEmailsRecipientMatchBlock(escapedQuery: String) -> String {
    let q = escapedQuery
    return """
    set _matched to false
    repeat with _r in (to recipients of msg)
        try
            if ((address of _r contains "\(q)") or (name of _r contains "\(q)")) then
                set _matched to true
                exit repeat
            end if
        end try
    end repeat
    if not _matched then
        repeat with _r in (cc recipients of msg)
            try
                if ((address of _r contains "\(q)") or (name of _r contains "\(q)")) then
                    set _matched to true
                    exit repeat
                end if
            end try
        end repeat
    end if
    """
}

/// Locale-independent AppleScript date construction + the `date received` bound
/// predicate. The setup builds `_qFrom` / `_qTo` from `current date` via component
/// setters (NEVER a `date "1/1/2026"` literal — that is parsed in the user's
/// region/locale → wrong instant). Components are taken in `Calendar.current`, so
/// the reconstructed local-tz date represents the same instant the SQLite path
/// compares against. Returns `("", "")` when both dates are nil.
func searchEmailsDateClause(dateFrom: Date?, dateTo: Date?) -> (setup: String, predicate: String) {
    var setups: [String] = []
    var predicates: [String] = []
    if let from = dateFrom {
        setups.append(searchEmailsDateVarSetup("_qFrom", from))
        predicates.append("date received ≥ _qFrom")
    }
    if let to = dateTo {
        setups.append(searchEmailsDateVarSetup("_qTo", to))
        predicates.append("date received ≤ _qTo")
    }
    return (setups.joined(separator: "\n"), predicates.joined(separator: " and "))
}

/// Emit the component-setter lines that build one AppleScript date variable.
/// `day` is reset to 1 before changing year/month to avoid a `Feb 30`-style
/// overflow when the seed `current date` lands on a 31st; `time` is seconds since
/// midnight.
private func searchEmailsDateVarSetup(_ varName: String, _ date: Date) -> String {
    let c = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute, .second], from: date)
    let year = c.year ?? 2000
    let month = c.month ?? 1
    let day = c.day ?? 1
    let secondsSinceMidnight = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    return [
        "set \(varName) to (current date)",
        "set day of \(varName) to 1",
        "set year of \(varName) to \(year)",
        "set month of \(varName) to \(month)",
        "set day of \(varName) to \(day)",
        "set time of \(varName) to \(secondsSinceMidnight)",
    ].joined(separator: "\n")
}

/// Assemble the text appended after `messages of <mailbox>` — either
/// ` whose <predicate>` or `""` (empty, when there is nothing to filter at the
/// `whose` level: `.recipient` with no date bound). Combines the field substring
/// predicate (for the fast-path fields) with the date predicate.
func searchEmailsWhoseSuffix(field: SearchField, escapedQuery: String, datePredicate: String) -> String {
    let fieldPredicate = searchEmailsFieldPredicate(field: field, escapedQuery: escapedQuery)
    let hasDate = !datePredicate.isEmpty
    switch (fieldPredicate, hasDate) {
    case (nil, false):
        return ""                                  // .recipient, no date → enumerate all, filter in-loop
    case (nil, true):
        return " whose \(datePredicate)"           // .recipient + date → date-only `whose`
    case (let predicate?, false):
        return " whose \(predicate)"               // field only → byte-compatible with pre-#194 (no parens)
    case (let predicate?, true):
        // field + date: the field group MUST be parenthesized before AND-joining
        // the date. AppleScript binds `and` tighter than `or`, so for `.any`
        // (`subject contains … or sender contains …`) an unparenthesized
        // `A or B and date` would parse as `A or (B and date)` — a subject match
        // OUTSIDE the date range would leak through, diverging from SQLite (which
        // ANDs the date as a separate condition). Parenthesizing is harmless for
        // the single-term fields and correct for `.any`.
        return " whose (\(predicate)) and \(datePredicate)"
    }
}
