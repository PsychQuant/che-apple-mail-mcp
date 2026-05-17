import XCTest
@testable import CheAppleMailMCP

/// Tests for `AppleScriptRefBuilder` — the shared account-disambiguation
/// reference builders for the #104 sweep.
///
/// `resolveMsgRef` / `resolveMailboxRef` are the single chokepoint every
/// AppleScript-routed tool calls: UUID-form `(account id "...")` selector
/// when `accountId` is provided, legacy `account "<display_name>"` form
/// when nil/empty (backward compat — byte-identical to the pre-sweep
/// `MailController.msgRef` / `mailboxRef` output).
final class AppleScriptRefBuilderTests: XCTestCase {

    // MARK: - mailboxRefByAccountId / msgRefByAccountId (moved from SaveAttachmentScriptBuilder)

    func testMailboxRefByAccountId_emitsAccountIdSelector() {
        XCTAssertEqual(
            mailboxRefByAccountId("INBOX", accountId: "UUID-A"),
            "(first mailbox of (account id \"UUID-A\") whose name is \"INBOX\")"
        )
    }

    func testMsgRefByAccountId_chainsRowId() {
        XCTAssertEqual(
            msgRefByAccountId("42", mailbox: "INBOX", accountId: "UUID-A"),
            "(first message of (first mailbox of (account id \"UUID-A\") whose name is \"INBOX\") whose id is 42)"
        )
    }

    // MARK: - resolveMailboxRef

    func testResolveMailboxRef_uuidPath_whenAccountIdProvided() {
        let ref = resolveMailboxRef(mailbox: "INBOX", accountId: "UUID-A", accountName: "kiki830621@gmail.com")
        XCTAssertEqual(
            ref,
            "(first mailbox of (account id \"UUID-A\") whose name is \"INBOX\")",
            "Non-nil accountId MUST use the (account id \"...\") UUID selector — display_name must NOT appear"
        )
        XCTAssertFalse(ref.contains("kiki830621@gmail.com"),
                       "display_name must not leak into the UUID-path ref")
    }

    func testResolveMailboxRef_displayNameFallback_whenAccountIdNil() {
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "INBOX", accountId: nil, accountName: "kiki830621@gmail.com"),
            "(first mailbox of account \"kiki830621@gmail.com\" whose name is \"INBOX\")",
            "Nil accountId MUST fall back to the legacy account \"<display_name>\" form — "
            + "byte-identical to pre-sweep MailController.mailboxRef output"
        )
    }

    func testResolveMailboxRef_displayNameFallback_whenAccountIdEmpty() {
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "INBOX", accountId: "", accountName: "alice@example.com"),
            "(first mailbox of account \"alice@example.com\" whose name is \"INBOX\")",
            "Empty-string accountId MUST be treated the same as nil"
        )
    }

    // MARK: - resolveMsgRef

    func testResolveMsgRef_uuidPath_whenAccountIdProvided() {
        let ref = resolveMsgRef(id: "263385", mailbox: "收件匣", accountId: "UUID-A",
                                accountName: "kiki830621@gmail.com")
        XCTAssertEqual(
            ref,
            "(first message of (first mailbox of (account id \"UUID-A\") whose name is \"收件匣\") whose id is 263385)",
            "Non-nil accountId MUST chain msgRefByAccountId"
        )
        XCTAssertFalse(ref.contains("kiki830621@gmail.com"),
                       "display_name must not leak into the UUID-path ref")
    }

    func testResolveMsgRef_displayNameFallback_whenAccountIdNil() {
        XCTAssertEqual(
            resolveMsgRef(id: "263385", mailbox: "INBOX", accountId: nil,
                          accountName: "kiki830621@gmail.com"),
            "(first message of (first mailbox of account \"kiki830621@gmail.com\" whose name is \"INBOX\") whose id is 263385)",
            "Nil accountId MUST fall back to the legacy form — byte-identical to "
            + "pre-sweep MailController.msgRef output"
        )
    }

    func testResolveMsgRef_displayNameFallback_whenAccountIdEmpty() {
        XCTAssertEqual(
            resolveMsgRef(id: "1", mailbox: "INBOX", accountId: "", accountName: "alice@example.com"),
            "(first message of (first mailbox of account \"alice@example.com\" whose name is \"INBOX\") whose id is 1)",
            "Empty-string accountId MUST be treated the same as nil"
        )
    }

    // MARK: - Escaping flows through both paths

    func testResolveMailboxRef_escapesQuotes_inBothPaths() {
        let uuidPath = resolveMailboxRef(mailbox: "Has\"Quote", accountId: "UUID-A", accountName: "a@b")
        XCTAssertTrue(uuidPath.contains("Has\\\"Quote"),
                      "Quote in mailbox name must be escaped in UUID path")
        let dnPath = resolveMailboxRef(mailbox: "INBOX", accountId: nil, accountName: "has\"quote@x")
        XCTAssertTrue(dnPath.contains("has\\\"quote@x"),
                      "Quote in display_name must be escaped in fallback path")
    }
}
