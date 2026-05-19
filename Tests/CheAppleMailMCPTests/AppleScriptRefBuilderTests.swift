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

    // MARK: - id injection hardening (#118 — release-safe guard, sister of #50)
    //
    // `resolveMsgRef` / `msgRefByAccountId` interpolate `id` unquoted into
    // `whose id is \(id)`. The pre-#118 guard was a debug-only `assert` that
    // compiles out under `-O`, so a release-build caller bypassing
    // `Server.requireMessageId` could inject an AppleScript predicate. The fix:
    // a release-safe `guard Int(id) != nil` that substitutes an impossible id
    // (`-1`) — the malicious string is NEVER interpolated into the output.

    func testMsgRefByAccountId_nonNumericId_substitutesSentinel() {
        let ref = msgRefByAccountId("1 or true", mailbox: "INBOX", accountId: "UUID-A")
        XCTAssertFalse(ref.contains("or true"),
                       "non-numeric id must NOT be interpolated — predicate injection surface")
        XCTAssertTrue(ref.contains("whose id is -1"),
                      "non-numeric id must collapse to the impossible-id sentinel; got:\n\(ref)")
    }

    func testResolveMsgRef_uuidPath_nonNumericId_substitutesSentinel() {
        let ref = resolveMsgRef(id: "1 or true", mailbox: "INBOX", accountId: "UUID-A",
                                accountName: "a@b")
        XCTAssertFalse(ref.contains("or true"),
                       "UUID-path non-numeric id must NOT be interpolated")
        XCTAssertTrue(ref.contains("whose id is -1"),
                      "UUID-path non-numeric id must collapse to the sentinel; got:\n\(ref)")
    }

    func testResolveMsgRef_fallbackPath_nonNumericId_substitutesSentinel() {
        let ref = resolveMsgRef(id: "263385) or true --", mailbox: "INBOX", accountId: nil,
                                accountName: "alice@example.com")
        XCTAssertFalse(ref.contains("or true"),
                       "fallback-path non-numeric id must NOT be interpolated")
        XCTAssertFalse(ref.contains("--"),
                       "fallback-path injection payload must NOT survive into the script")
        XCTAssertTrue(ref.contains("whose id is -1"),
                      "fallback-path non-numeric id must collapse to the sentinel; got:\n\(ref)")
    }

    func testResolveMsgRef_numericId_byteEquivalencePreserved() {
        // The valid (numeric) path must be byte-identical to pre-#118 output —
        // the guard interpolates the ORIGINAL id string, not a round-tripped Int.
        XCTAssertEqual(
            resolveMsgRef(id: "263385", mailbox: "INBOX", accountId: nil,
                          accountName: "alice@example.com"),
            "(first message of (first mailbox of account \"alice@example.com\" whose name is \"INBOX\") whose id is 263385)"
        )
        XCTAssertEqual(
            msgRefByAccountId("42", mailbox: "INBOX", accountId: "UUID-A"),
            "(first message of (first mailbox of (account id \"UUID-A\") whose name is \"INBOX\") whose id is 42)"
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

    // MARK: - resolveAccountRef (#104 PR-D)
    //
    // Account-only selector resolver. Unlike resolveMsgRef / resolveMailboxRef
    // (which return a full message / mailbox reference), resolveAccountRef
    // returns just the account selector — needed by `create_mailbox`, whose
    // AppleScript addresses an account directly (`... at account "<name>"`)
    // rather than referencing an existing mail item.

    func testResolveAccountRef_uuidPath_whenAccountIdProvided() {
        let ref = resolveAccountRef(accountId: "UUID-A", accountName: "kiki830621@gmail.com")
        XCTAssertEqual(
            ref,
            "(account id \"UUID-A\")",
            "Non-nil accountId MUST use the (account id \"...\") UUID selector"
        )
        XCTAssertFalse(ref.contains("kiki830621@gmail.com"),
                       "display_name must not leak into the UUID-path ref")
    }

    func testResolveAccountRef_displayNameFallback_whenAccountIdNil() {
        XCTAssertEqual(
            resolveAccountRef(accountId: nil, accountName: "kiki830621@gmail.com"),
            "account \"kiki830621@gmail.com\"",
            "Nil accountId MUST fall back to the legacy account \"<display_name>\" form"
        )
    }

    func testResolveAccountRef_displayNameFallback_whenAccountIdEmpty() {
        XCTAssertEqual(
            resolveAccountRef(accountId: "", accountName: "alice@example.com"),
            "account \"alice@example.com\"",
            "Empty-string accountId MUST be treated the same as nil"
        )
    }

    func testResolveAccountRef_escapesQuotes_inBothPaths() {
        let uuidPath = resolveAccountRef(accountId: "uuid\"x", accountName: "a@b")
        XCTAssertTrue(uuidPath.contains("uuid\\\"x"),
                      "Quote in accountId must be escaped in UUID path")
        let dnPath = resolveAccountRef(accountId: nil, accountName: "has\"quote@x")
        XCTAssertTrue(dnPath.contains("has\\\"quote@x"),
                      "Quote in display_name must be escaped in fallback path")
    }
}
