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

    /// Partial supply: an explicit account_id (the #101 disambiguation selector)
    /// must survive even when the mailbox has to be derived.
    func testExplicitAccountIdSurvivesDerivedMailbox() {
        let a = CheAppleMailMCPServer.resolveFallbackAddressing(
            suppliedMailbox: nil, suppliedAccountId: "EXPLICIT-UUID",
            suppliedAccountName: nil, derived: derived)
        XCTAssertEqual(a?.accountId, "EXPLICIT-UUID", "explicit account_id must not be overwritten by the derived one")
        XCTAssertEqual(a?.mailbox, "收件匣", "mailbox still derived")
        XCTAssertEqual(a?.usedDerived, true)
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
