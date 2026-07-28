import XCTest
import Foundation
@testable import CheAppleMailMCP

/// Tests for the #299 rowId-self-addressing helpers: deriving the AppleScript
/// addressing pair (account UUID + real mailbox path) straight from the
/// Envelope Index, so `get_email`'s materialization nudge is reachable without
/// the caller naming an account the pipeline never gave them.
///
/// All three helpers are pure — the resolver parses a URL, the addressing
/// decision is a precedence table, and the retry gate is a code test — so the
/// contract is testable without Mail or the actor.
final class MessageLocationResolverTests: XCTestCase {

    // MARK: - resolveMessageLocation (URL → addressing pair)

    /// The #299 case: an Exchange/EWS mailbox URL yields the account UUID and
    /// the account's REAL (localized) mailbox name — the pair the caller could
    /// not supply.
    func testResolvesEwsUrlToUuidAndLocalizedPath() {
        let r = resolveMessageLocation(fromMailboxURL: "ews://ABCE3A85-06BE-43BC-9B84-2CA6F325612F/%E6%94%B6%E4%BB%B6%E5%8C%A3")
        XCTAssertEqual(r?.accountId, "ABCE3A85-06BE-43BC-9B84-2CA6F325612F")
        XCTAssertEqual(r?.mailboxPath, "收件匣", "percent-encoded localized name must be decoded")
    }

    /// A nested on-disk path must survive intact — `resolveMailboxRef` rewrites
    /// it into an AppleScript container chain (#174); truncating to the leaf
    /// here would silently address the wrong mailbox.
    func testResolvesNestedImapPathIntact() {
        let r = resolveMessageLocation(fromMailboxURL: "imap://E51B96AC-9499-4FCC-9638-18F2A300EBFE/%5BGmail%5D/%E5%85%A8%E9%83%A8%E9%83%B5%E4%BB%B6")
        XCTAssertEqual(r?.accountId, "E51B96AC-9499-4FCC-9638-18F2A300EBFE")
        XCTAssertEqual(r?.mailboxPath, "[Gmail]/全部郵件", "nested path must keep its separator, not collapse to the leaf")
    }

    /// Malformed / unusable URLs must yield nil so the caller keeps whatever it
    /// was explicitly given instead of addressing with an empty selector (an
    /// empty accountId would silently fall back to a display-name selector).
    func testReturnsNilOnUnusableUrls() {
        XCTAssertNil(resolveMessageLocation(fromMailboxURL: ""), "empty string")
        XCTAssertNil(resolveMessageLocation(fromMailboxURL: "not-a-url"), "no scheme separator")
        XCTAssertNil(resolveMessageLocation(fromMailboxURL: "imap://UUID-ONLY"), "no mailbox path")
        XCTAssertNil(resolveMessageLocation(fromMailboxURL: "imap:///INBOX"), "empty account uuid")
        XCTAssertNil(resolveMessageLocation(fromMailboxURL: "imap://UUID-A/"), "empty mailbox path")
    }

    // MARK: - resolveFallbackAddressing (precedence table)

    private let derived = ResolvedMessageLocation(accountId: "DERIVED-UUID", mailboxPath: "收件匣")

    /// Backward compatibility (the #299 top risk): when the caller supplies the
    /// pair explicitly, it is used verbatim and the derived values are ignored —
    /// pre-#299 behavior byte-for-byte.
    func testExplicitPairWinsAndIsNotDerived() {
        let a = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: "INBOX", suppliedAccountId: nil,
            suppliedAccountName: "Google", derived: derived)
        XCTAssertEqual(a?.mailbox, "INBOX")
        XCTAssertEqual(a?.accountName, "Google")
        XCTAssertNil(a?.accountId, "no account_id was supplied and none must be invented when the pair is explicit")
        XCTAssertEqual(a?.usedDerived, false)
    }

    /// The #299 fix: with no mailbox/account supplied, the rowId's own index
    /// entry addresses the message — via the globally-unique UUID selector.
    func testDerivesWhenNothingSupplied() {
        let a = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: nil, suppliedAccountId: nil,
            suppliedAccountName: nil, derived: derived)
        XCTAssertEqual(a?.mailbox, "收件匣")
        XCTAssertEqual(a?.accountId, "DERIVED-UUID")
        XCTAssertEqual(a?.usedDerived, true)
    }

    /// **The pair is atomic** (verify: all three lenses). A mailbox name is only
    /// meaningful within an account, so a PARTIAL supply must never be merged
    /// with the derived half: with two accounts that both contain `Archive` (or
    /// `[Gmail]/…`), grafting a derived mailbox path onto a caller-named account
    /// yields a specifier that RESOLVES — against the wrong account.
    func testPartialSupply_accountOnly_usesWholeDerivedPair() {
        let a = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: nil, suppliedAccountId: "EXPLICIT-UUID",
            suppliedAccountName: nil, derived: derived)
        XCTAssertEqual(a?.accountId, "DERIVED-UUID",
                       "a half-supplied selector must not be merged — the rowId's own entry wins whole")
        XCTAssertEqual(a?.mailbox, "收件匣")
        XCTAssertEqual(a?.usedDerived, true, "must be flagged as derived so the handler can disclose it")
    }

    /// The mirror case — and the one that motivated #299: a `search_emails`
    /// `summary` projection hands the caller a `mailbox` but NO account, so this
    /// is the single most common partial supply in the wild.
    func testPartialSupply_mailboxOnly_usesWholeDerivedPair() {
        let a = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: "INBOX", suppliedAccountId: nil,
            suppliedAccountName: nil, derived: derived)
        XCTAssertEqual(a?.mailbox, "收件匣",
                       "a mailbox guess without an account must not be grafted onto the derived account")
        XCTAssertEqual(a?.accountId, "DERIVED-UUID")
        XCTAssertEqual(a?.usedDerived, true)
    }

    /// A complete caller pair keeps its exact selector — and `accountName` is
    /// zeroed when a UUID is present so two addressings that select the same
    /// target compare equal (the retry gate depends on that).
    func testCompletePairWithAccountId_normalizesAccountName() {
        let a = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: "INBOX", suppliedAccountId: "EXPLICIT-UUID",
            suppliedAccountName: "Google", derived: derived)
        XCTAssertEqual(a?.mailbox, "INBOX")
        XCTAssertEqual(a?.accountId, "EXPLICIT-UUID")
        XCTAssertEqual(a?.accountName, "", "an unused display name must not make equality provenance-sensitive")
        XCTAssertEqual(a?.usedDerived, false)
    }

    /// The retry gate compares TARGETS, not provenance.
    func testAddressesSameTarget_comparesSelectorTripleOnly() {
        let supplied = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: "收件匣", suppliedAccountId: "DERIVED-UUID",
            suppliedAccountName: nil, derived: derived)
        let derivedOnly = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: nil, suppliedAccountId: nil, suppliedAccountName: nil, derived: derived)
        XCTAssertNotEqual(supplied?.usedDerived, derivedOnly?.usedDerived, "provenance differs")
        XCTAssertTrue(CheAppleMailMCPServer.addressesSameTarget(
            try! XCTUnwrap(supplied), try! XCTUnwrap(derivedOnly)),
            "a caller who supplied exactly the derived pair must NOT trigger a duplicate retry")

        let elsewhere = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: "Archive", suppliedAccountId: "OTHER-UUID",
            suppliedAccountName: nil, derived: derived)
        XCTAssertFalse(CheAppleMailMCPServer.addressesSameTarget(
            try! XCTUnwrap(elsewhere), try! XCTUnwrap(derivedOnly)),
            "a different target must arm the retry")
    }

    /// Empty strings are treated as absent, not as a real selector — an empty
    /// mailbox name can never resolve and would mask the derivable answer.
    func testEmptyStringsCountAsAbsent() {
        let a = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: "", suppliedAccountId: "",
            suppliedAccountName: "", derived: derived)
        XCTAssertEqual(a?.mailbox, "收件匣")
        XCTAssertEqual(a?.accountId, "DERIVED-UUID")
        XCTAssertEqual(a?.usedDerived, true)
    }

    /// Resolver rejections that keep the caller on the explicit path rather than
    /// addressing the WRONG object (verify: Lens A/B).
    func testDeclinesToDeriveWhenAddressingWouldBeAmbiguousOrInvalid() {
        // %2F is a slash INSIDE one mailbox name; decoding then splitting on "/"
        // would silently address a nested pair instead.
        XCTAssertNil(resolveMessageLocation(
            fromMailboxURL: "imap://E51B96AC-9499-4FCC-9638-18F2A300EBFE/R%26D%2FLegal"),
            "an encoded %2F is unresolvable under the decode-then-split contract — decline")
        // A non-UUID authority would emit an `account id "…"` that can never resolve.
        XCTAssertNil(resolveMessageLocation(fromMailboxURL: "imap://user@imap.example.com/INBOX"),
                     "non-UUID authority must not be emitted as an account id selector")
        XCTAssertNil(resolveMessageLocation(fromMailboxURL: "local://On My Mac/Notes"),
                     "a local mailbox has no account UUID")
        // Empty segments would emit `mailbox ""` into the container chain.
        XCTAssertNil(resolveMessageLocation(
            fromMailboxURL: "imap://E51B96AC-9499-4FCC-9638-18F2A300EBFE/%5BGmail%5D//Sub"),
            "an empty path segment must not become an empty mailbox selector")
        // A well-formed UUID still resolves (guard against over-rejection).
        XCTAssertNotNil(resolveMessageLocation(
            fromMailboxURL: "imap://E51B96AC-9499-4FCC-9638-18F2A300EBFE/INBOX"))
    }

    /// No derived location AND an incomplete supply → nil, so the handler can
    /// throw the actionable "supply mailbox/account_name" error instead of
    /// addressing Mail with a half-empty selector.
    func testNilWhenUnaddressable() {
        XCTAssertNil(CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: nil, suppliedAccountId: nil,
            suppliedAccountName: nil, derived: nil), "nothing supplied, nothing derivable")
        XCTAssertNil(CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: "INBOX", suppliedAccountId: nil,
            suppliedAccountName: nil, derived: nil), "mailbox alone cannot address an account")
        XCTAssertNil(CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: nil, suppliedAccountId: "UUID", suppliedAccountName: nil,
            derived: nil), "account alone cannot address a mailbox")
    }

    /// The retry path forces derivation: a caller-supplied pair that failed
    /// AppleScript resolution must be discarded, not merged.
    func testForcedDerivationIgnoresSuppliedValues() {
        let a = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: nil, suppliedAccountId: nil, suppliedAccountName: nil,
            derived: derived)
        XCTAssertEqual(a?.mailbox, derived.mailboxPath)
        XCTAssertEqual(a?.accountId, derived.accountId)
        XCTAssertTrue(a?.usedDerived ?? false)
    }

    // MARK: - unaddressableMessageHint (cause-specific diagnosis)

    /// The three ways a message can be unaddressable need three different user
    /// actions (grant FDA / check the id / supply selectors), so one generic
    /// sentence would misdirect (verify: Lens A P2).
    func testUnaddressableHint_namesTheActualCause() {
        let noIndex = CheAppleMailMCPServer.unaddressableMessageHint(
            id: "42", indexAvailable: false, rowIdIndexed: false)
        XCTAssertTrue(noIndex.contains("Full Disk Access") || noIndex.contains("check_fda"),
                      "an unavailable index is a permissions problem; got: \(noIndex)")

        let notIndexed = CheAppleMailMCPServer.unaddressableMessageHint(
            id: "42", indexAvailable: true, rowIdIndexed: false)
        XCTAssertTrue(notIndexed.contains("not in the Envelope Index"),
                      "a missing rowId must say so; got: \(notIndexed)")
        XCTAssertFalse(notIndexed.contains("Full Disk Access"),
                       "must not misdirect to permissions when the index is fine")

        let underivable = CheAppleMailMCPServer.unaddressableMessageHint(
            id: "42", indexAvailable: true, rowIdIndexed: true)
        XCTAssertTrue(underivable.contains("On-My-Mac") || underivable.contains("ambiguous")
                      || underivable.contains("'/'"),
                      "an indexed-but-underivable entry must name the real reasons; got: \(underivable)")

        for hint in [noIndex, notIndexed, underivable] {
            XCTAssertTrue(hint.contains("42"), "the hint must name the id it is about")
            XCTAssertTrue(hint.contains("#299"), "traceable to the change that introduced the path")
        }
    }

    // MARK: - shouldRetryWithDerivedLocation (the -1719 gate)

    /// Only the two ADDRESSING failures retry. -1719 is the "invalid index"
    /// the #299 report recorded (mailbox/message selector matched nothing) and
    /// -1728 is "can't get object" (account selector matched nothing).
    func testRetriesOnlyOnAddressingFailures() {
        XCTAssertTrue(shouldRetryWithDerivedLocation(code: -1719), "invalid index → the selector was wrong")
        XCTAssertTrue(shouldRetryWithDerivedLocation(code: -1728), "can't get object → the selector was wrong")
        XCTAssertFalse(shouldRetryWithDerivedLocation(code: -10000),
                       "generic AppleEvent failure is not an addressing problem — retrying re-runs a real failure")
        XCTAssertFalse(shouldRetryWithDerivedLocation(code: -1743),
                       "not authorized is a TCC problem; a different selector cannot fix it")
        XCTAssertFalse(shouldRetryWithDerivedLocation(code: 0), "success code must never trigger a retry")
    }
}
