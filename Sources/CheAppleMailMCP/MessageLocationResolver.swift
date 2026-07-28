import Foundation
import MailSQLite

/// rowId self-addressing for the AppleScript fallback (#299).
///
/// ## Why this exists
///
/// `get_email`'s AppleScript fallback doubles as the **body-materialization
/// nudge** (#274): when the fast path finds only a partial `.emlx` with an
/// empty body, reading the message through Mail asks Mail to fetch it. Reaching
/// that nudge used to require the caller to pass `mailbox` + `account_name` —
/// but the tools that *produce* the ids needing a nudge never return an
/// account: an export manifest item carries `id` / `message_id` / `status`, and
/// `search_emails`' `summary` projection is `id/date/sender/subject/mailbox`.
/// A guessed account fails AppleScript resolution (`-1719 invalid index`), the
/// nudge is never delivered, and the symptom reads as "this account's bodies
/// cannot be materialized" (#299, reported against Exchange/EWS — where live
/// probes confirmed both `.emlx` storage and working AppleScript resolution).
///
/// The Envelope Index already knows the answer, and a **better** one than the
/// caller can give: the mailbox URL yields the account **UUID** (globally
/// unique — the `account id "…"` selector, immune to the display-name collision
/// class of #101/#176) plus the account's real, localized mailbox path. So the
/// rowId is self-sufficient; the two parameters are redundant at best.
///
/// Pure + actor-free by design: parsing, a precedence table, and a code gate —
/// all unit-testable without Mail (same pattern as `SpecialMailboxesScriptBuilder`).

// MARK: - Derived addressing pair

/// The AppleScript addressing pair derived from a message's Envelope Index entry.
struct ResolvedMessageLocation: Equatable {
    /// Account UUID — feeds the globally-unique `account id "…"` selector.
    let accountId: String
    /// The account's real mailbox path, percent-decoded and possibly nested
    /// (`[Gmail]/全部郵件`). Passed through unchanged: `resolveMailboxRef`
    /// rewrites a nested path into an AppleScript container chain (#174), so
    /// truncating it to the leaf here would silently address a different mailbox.
    let mailboxPath: String
}

/// Derive the addressing pair from a raw Envelope Index mailbox URL
/// (`ews://<uuid>/<percent-encoded path>`).
///
/// Declines (returns nil) rather than emitting an addressing that could resolve
/// to the WRONG object. Every rejection below leaves the caller on the explicit
/// `mailbox` + `account_name` path, which is exactly the pre-#299 behavior:
///
/// - **Non-UUID authority.** The value is emitted as `account id "…"`. Mail's
///   Envelope Index uses account UUIDs (`ews://ABCE3A85-…/`), but a URL shaped
///   `imap://user@host/INBOX` would produce a selector that can never resolve —
///   fail fast instead of dead-ending at -1728 (verify Lens A/B).
/// - **`%2F` in the encoded path.** `mailboxPath` is percent-DECODED and
///   `resolveMailboxRef` then splits it on "/" to build the container chain
///   (#174). An encoded `%2F` is a slash *inside a single mailbox name*, which
///   that split would silently reinterpret as hierarchy — addressing a different
///   mailbox. The ambiguity is unresolvable without a components-based API, so
///   we decline to derive (verify Lens A/B; the caller can still pass the name
///   explicitly, where the ambiguity is theirs and pre-existing).
/// - **Empty path segments** (leading "/", "//", trailing "/") would emit
///   `mailbox ""` into the chain — a degenerate selector.
func resolveMessageLocation(fromMailboxURL urlString: String) -> ResolvedMessageLocation? {
    // Checked on the RAW string: decoding is what erases the distinction.
    guard urlString.range(of: "%2F", options: .caseInsensitive) == nil else { return nil }
    guard let parsed = MailboxURL.decode(urlString) else { return nil }
    guard isAccountUUID(parsed.accountUUID) else { return nil }
    let path = parsed.mailboxPath
    guard !path.isEmpty else { return nil }
    // Every segment must be a usable AppleScript mailbox name.
    let segments = path.components(separatedBy: "/")
    guard !segments.contains(where: { $0.isEmpty }) else { return nil }
    guard !segments.contains(where: { seg in
        seg.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }) else { return nil }
    return ResolvedMessageLocation(accountId: parsed.accountUUID, mailboxPath: path)
}

/// Mail account identifiers in the Envelope Index are UUIDs (8-4-4-4-12 hex).
/// Anything else is not an `account id` selector.
func isAccountUUID(_ s: String) -> Bool {
    let parts = s.components(separatedBy: "-")
    guard parts.count == 5,
          parts[0].count == 8, parts[1].count == 4, parts[2].count == 4,
          parts[3].count == 4, parts[4].count == 12 else { return false }
    return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
}

/// Should a failed AppleScript read be retried with the derived addressing?
///
/// Only the two **addressing** failures qualify: `-1719` (invalid index — the
/// mailbox/message selector matched nothing; the code the #299 report recorded)
/// and `-1728` (can't get object — the account selector matched nothing). Every
/// other code is a real failure a different selector cannot fix: `-10000` is the
/// generic AppleEvent failure (e.g. an unfetched binary, #238), `-1743` is a TCC
/// denial (#287). Retrying those would re-run a genuine error and mask its cause.
func shouldRetryWithDerivedLocation(code: Int) -> Bool {
    return code == -1719 || code == -1728
}

// MARK: - Precedence

extension CheAppleMailMCPServer {

    /// The addressing the AppleScript fallback should actually use.
    struct EmailFallbackAddressing: Equatable {
        let mailbox: String
        /// nil when no account UUID is in play — `accountName` then selects.
        let accountId: String?
        /// Display-name selector; `""` when an `accountId` makes it unused.
        let accountName: String
        /// True when any field came from the Envelope Index rather than the caller.
        let usedDerived: Bool
    }

    /// Combine caller-supplied selectors with the derived pair.
    ///
    /// **The pair is ATOMIC.** A mailbox name is only meaningful *within* an
    /// account, so the two halves are never taken from different sources. An
    /// earlier per-field precedence (mailbox from one source, account from the
    /// other) was rejected in verify: with two accounts that both contain e.g.
    /// `Archive` or `[Gmail]/…`, grafting a derived mailbox path onto a
    /// caller-named account produces a specifier that RESOLVES — against the
    /// wrong account — which is the #101 hazard this file otherwise avoids.
    ///
    /// So there are exactly two outcomes:
    /// - the caller supplied a **complete** pair (mailbox + an account selector)
    ///   → use it verbatim, `usedDerived == false` (pre-#299 byte-for-byte);
    /// - otherwise → use the **whole** derived pair, `usedDerived == true`.
    ///
    /// A partial supply is therefore *ignored*, not merged. That is deliberate:
    /// the rowId's own index entry is authoritative for where the message
    /// actually lives, and a half-supplied selector is a guess (the caller who
    /// has a `mailbox` but no account got it from a `summary` projection — the
    /// exact population #299 exists to serve). The handler discloses the
    /// substitution in the result so the choice is never invisible.
    ///
    /// Empty strings count as absent (an empty selector can never resolve).
    ///
    /// - Returns: nil when the message is unaddressable — an incomplete supply
    ///   with nothing derivable. The caller then throws the actionable error
    ///   instead of sending Mail a half-empty selector.
    static func resolveFallbackAddressing(
        suppliedMailbox: String?,
        suppliedAccountId: String?,
        suppliedAccountName: String?,
        derived: ResolvedMessageLocation?
    ) -> EmailFallbackAddressing? {
        // Normalize: absent and empty are the same thing here.
        let mailboxIn = suppliedMailbox.flatMap { $0.isEmpty ? nil : $0 }
        let accountIdIn = suppliedAccountId.flatMap { $0.isEmpty ? nil : $0 }
        let accountNameIn = suppliedAccountName.flatMap { $0.isEmpty ? nil : $0 }

        // Complete caller-supplied pair → verbatim. `accountName` is zeroed when
        // a UUID is present (resolveMailboxRef ignores it there), so two
        // addressings that select the same target compare equal — the retry gate
        // depends on that.
        if let mailbox = mailboxIn, accountIdIn != nil || accountNameIn != nil {
            return EmailFallbackAddressing(
                mailbox: mailbox,
                accountId: accountIdIn,
                accountName: accountIdIn != nil ? "" : (accountNameIn ?? ""),
                usedDerived: false)
        }

        // Anything less → the whole derived pair, or nothing.
        guard let d = derived else { return nil }
        return EmailFallbackAddressing(
            mailbox: d.mailboxPath, accountId: d.accountId,
            accountName: "", usedDerived: true)
    }

    /// Do two addressings select the same target? Compares the selector triple
    /// only — `usedDerived` records provenance, not destination. Used to gate
    /// the retry so it never re-runs the call that just failed.
    static func addressesSameTarget(_ a: EmailFallbackAddressing,
                                    _ b: EmailFallbackAddressing) -> Bool {
        return a.mailbox == b.mailbox && a.accountId == b.accountId && a.accountName == b.accountName
    }
}
