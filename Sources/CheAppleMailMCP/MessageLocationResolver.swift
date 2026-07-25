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
/// - Returns: nil when the URL cannot yield BOTH a non-empty account UUID and a
///   non-empty mailbox path. Returning nil (rather than a half-filled value) is
///   load-bearing: an empty `accountId` would make `resolveAccountRef` silently
///   fall back to a display-name selector — exactly the ambiguity this bypasses.
func resolveMessageLocation(fromMailboxURL urlString: String) -> ResolvedMessageLocation? {
    guard let parsed = MailboxURL.decode(urlString) else { return nil }
    guard !parsed.accountUUID.isEmpty, !parsed.mailboxPath.isEmpty else { return nil }
    return ResolvedMessageLocation(accountId: parsed.accountUUID, mailboxPath: parsed.mailboxPath)
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
    /// **Explicit values always win** — a caller who passes `mailbox` +
    /// `account_name` gets pre-#299 behavior byte-for-byte; derivation only
    /// fills what is absent. Empty strings count as absent (an empty mailbox
    /// name can never resolve, and treating it as a real selector would mask
    /// the derivable answer).
    ///
    /// - Returns: nil when the message is unaddressable — no mailbox, or no
    ///   account selector at all. The caller then throws the actionable error
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

        guard let mailbox = mailboxIn ?? derived?.mailboxPath else { return nil }

        // Account selector: explicit UUID > explicit display name > derived UUID.
        // The display name is honored before deriving so an explicit
        // `account_name`-only call keeps its exact pre-#299 selector.
        let accountId: String?
        let accountName: String
        if let aid = accountIdIn {
            accountId = aid
            accountName = accountNameIn ?? ""
        } else if let an = accountNameIn {
            accountId = nil
            accountName = an
        } else if let d = derived {
            accountId = d.accountId
            accountName = ""
        } else {
            return nil   // no account selector obtainable
        }

        let usedDerived = (mailboxIn == nil) || (accountIdIn == nil && accountNameIn == nil)
        return EmailFallbackAddressing(
            mailbox: mailbox, accountId: accountId,
            accountName: accountName, usedDerived: usedDerived)
    }
}
