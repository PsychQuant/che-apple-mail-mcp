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
        let ref = resolveMailboxRef(mailbox: "INBOX", accountId: "UUID-A", accountName: "alice@example.com")
        XCTAssertEqual(
            ref,
            "(first mailbox of (account id \"UUID-A\") whose name is \"INBOX\")",
            "Non-nil accountId MUST use the (account id \"...\") UUID selector — display_name must NOT appear"
        )
        XCTAssertFalse(ref.contains("alice@example.com"),
                       "display_name must not leak into the UUID-path ref")
    }

    func testResolveMailboxRef_displayNameFallback_whenAccountIdNil() {
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "INBOX", accountId: nil, accountName: "alice@example.com"),
            "(first mailbox of account \"alice@example.com\" whose name is \"INBOX\")",
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
                                accountName: "alice@example.com")
        XCTAssertEqual(
            ref,
            "(first message of (first mailbox of (account id \"UUID-A\") whose name is \"收件匣\") whose id is 263385)",
            "Non-nil accountId MUST chain msgRefByAccountId"
        )
        XCTAssertFalse(ref.contains("alice@example.com"),
                       "display_name must not leak into the UUID-path ref")
    }

    func testResolveMsgRef_displayNameFallback_whenAccountIdNil() {
        XCTAssertEqual(
            resolveMsgRef(id: "263385", mailbox: "INBOX", accountId: nil,
                          accountName: "alice@example.com"),
            "(first message of (first mailbox of account \"alice@example.com\" whose name is \"INBOX\") whose id is 263385)",
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
        let ref = resolveAccountRef(accountId: "UUID-A", accountName: "alice@example.com")
        XCTAssertEqual(
            ref,
            "(account id \"UUID-A\")",
            "Non-nil accountId MUST use the (account id \"...\") UUID selector"
        )
        XCTAssertFalse(ref.contains("alice@example.com"),
                       "display_name must not leak into the UUID-path ref")
    }

    func testResolveAccountRef_displayNameFallback_whenAccountIdNil() {
        XCTAssertEqual(
            resolveAccountRef(accountId: nil, accountName: "alice@example.com"),
            "account \"alice@example.com\"",
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

    // MARK: - Nested mailbox paths (#174 — Gmail [Gmail]/X container chain)
    //
    // MailSQLite emits mailbox names in on-disk path form (`[Gmail]/全部郵件`).
    // Mail's AppleScript `name` property holds only the LEAF name, so the
    // legacy `whose name is "<full path>"` form can never match a nested
    // mailbox (-1719). Empirically verified 2026-06-11 (issue #174 plan):
    // `mailbox "草稿" of mailbox "[Gmail]" of (account id "...")` resolves,
    // so slash-containing names are rewritten into a container chain.
    // Names WITHOUT "/" keep the legacy form byte-identical (#104 guard).

    func testResolveMailboxRef_nestedPath_uuidPath_buildsContainerChain() {
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "[Gmail]/全部郵件", accountId: "UUID-A",
                              accountName: "alice@example.com"),
            "(mailbox \"全部郵件\" of mailbox \"[Gmail]\" of (account id \"UUID-A\"))",
            "Slash-containing mailbox must become a container chain, not whose-name-is"
        )
    }

    func testResolveMailboxRef_nestedPath_displayNameFallback_buildsContainerChain() {
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "[Gmail]/草稿", accountId: nil,
                              accountName: "alice@example.com"),
            "(mailbox \"草稿\" of mailbox \"[Gmail]\" of account \"alice@example.com\")",
            "Chain rewrite must apply to the display_name fallback path too"
        )
    }

    func testMailboxRefByAccountId_nestedPath_buildsContainerChain() {
        XCTAssertEqual(
            mailboxRefByAccountId("[Gmail]/全部郵件", accountId: "UUID-A"),
            "(mailbox \"全部郵件\" of mailbox \"[Gmail]\" of (account id \"UUID-A\"))"
        )
    }

    func testResolveMailboxRef_threeSegments_chainsRightToLeft() {
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "A/B/C", accountId: "UUID-A", accountName: "a@b"),
            "(mailbox \"C\" of mailbox \"B\" of mailbox \"A\" of (account id \"UUID-A\"))",
            "Deeper nesting must chain leaf-first back to the account"
        )
    }

    func testResolveMsgRef_nestedPath_chainsThroughContainer() {
        XCTAssertEqual(
            resolveMsgRef(id: "274368", mailbox: "[Gmail]/全部郵件", accountId: "UUID-A",
                          accountName: "a@b"),
            "(first message of (mailbox \"全部郵件\" of mailbox \"[Gmail]\" of (account id \"UUID-A\")) whose id is 274368)",
            "Message refs must address nested mailboxes through the container chain"
        )
    }

    func testResolveMailboxRef_nestedPath_escapesQuotesPerSegment() {
        let ref = resolveMailboxRef(mailbox: "[Gmail]/Has\"Quote", accountId: "UUID-A",
                                    accountName: "a@b")
        XCTAssertTrue(ref.contains("Has\\\"Quote"),
                      "Quote inside a path segment must be escaped; got:\n\(ref)")
        XCTAssertFalse(ref.contains("whose name is"),
                       "Slash-containing name must not fall back to whose-name-is")
    }

    func testResolveMailboxRef_consecutiveSlashes_emptySegmentsFiltered() {
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "[Gmail]//全部郵件", accountId: "UUID-A", accountName: "a@b"),
            "(mailbox \"全部郵件\" of mailbox \"[Gmail]\" of (account id \"UUID-A\"))",
            "Empty segments from consecutive slashes must be dropped"
        )
    }

    func testResolveMailboxRef_slashOnlyName_keepsLegacyForm() {
        // Degenerate input: after filtering empty segments fewer than 2 remain —
        // keep the legacy whole-string form (same failure surface as today,
        // no behavior change for names that merely CONTAIN a stray slash).
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "/", accountId: "UUID-A", accountName: "a@b"),
            "(first mailbox of (account id \"UUID-A\") whose name is \"/\")",
            "Fewer than 2 non-empty segments must keep the legacy whose-name-is form"
        )
    }

    func testResolveMailboxRef_noSlash_byteIdentityGuard() {
        // Explicit #174 regression lock on top of the existing #104 tests:
        // names without "/" must keep the EXACT pre-#174 output in both paths.
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "收件匣", accountId: "UUID-A", accountName: "a@b"),
            "(first mailbox of (account id \"UUID-A\") whose name is \"收件匣\")"
        )
        XCTAssertEqual(
            resolveMailboxRef(mailbox: "收件匣", accountId: nil, accountName: "alice@example.com"),
            "(first mailbox of account \"alice@example.com\" whose name is \"收件匣\")"
        )
    }
}
