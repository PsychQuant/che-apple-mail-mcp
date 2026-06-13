import XCTest
@testable import CheAppleMailMCP

/// Tests for `MailController.msgRef`'s release-safe id guard (#145 — sister of
/// #118, which hardened the identical pattern in `AppleScriptRefBuilder`).
///
/// `msgRef` interpolates message `id` unquoted into `whose id is <id>`. The
/// pre-#145 guard was a debug-only `assert` that compiles out under `-O`, so a
/// release-build caller bypassing `Server.requireMessageId` could inject an
/// AppleScript predicate. The fix substitutes an impossible id (`-1`) for any
/// non-numeric input — the malicious string is never interpolated.
///
/// `msgRef` is `internal` (not `private`) purely as the test seam; it is an
/// actor-isolated method on `MailController`, exercised here via the shared
/// instance (it is pure — no actor state, no I/O — so the hop is trivial).
final class MailControllerMsgRefTests: XCTestCase {

    func testMsgRef_nonNumericId_substitutesSentinel() async {
        let ref = await MailController.shared.msgRef(
            "1 or true", mailbox: "INBOX", account: "alice@example.com")
        XCTAssertFalse(ref.contains("or true"),
                       "non-numeric id must NOT be interpolated — predicate injection surface")
        XCTAssertTrue(ref.contains("whose id is -1"),
                      "non-numeric id must collapse to the impossible-id sentinel; got:\n\(ref)")
    }

    func testMsgRef_injectionPayloadWithMetacharacters_neutralized() async {
        let ref = await MailController.shared.msgRef(
            "263385) or true --", mailbox: "INBOX", account: "alice@example.com")
        XCTAssertFalse(ref.contains("or true"),
                       "metacharacter payload must NOT survive into the script")
        XCTAssertFalse(ref.contains("--"))
        XCTAssertTrue(ref.contains("whose id is -1"))
    }

    func testMsgRef_numericId_byteEquivalencePreserved() async {
        // Valid numeric id → byte-identical to the pre-#145 output (the guard
        // interpolates the original id string, not a round-tripped Int).
        //
        // #180: `msgRef` now DELEGATES to `resolveMsgRef` (the shared
        // chokepoint) instead of inlining the legacy `account "X" whose name`
        // template. This assertion doubles as the #180 byte-identity lock for
        // the `accountId: nil` (default) path — if the delegation ever shifts
        // the bytes, this fails.
        let ref = await MailController.shared.msgRef(
            "263385", mailbox: "INBOX", account: "alice@example.com")
        XCTAssertEqual(
            ref,
            "(first message of (first mailbox of account \"alice@example.com\" whose name is \"INBOX\") whose id is 263385)"
        )
    }

    // MARK: - #180: accountId threads through the chokepoint

    /// #180 second half: a non-empty `accountId` must switch the account
    /// selector to Mail.app's globally-unique `account id "<UUID>"` form. This
    /// is what lets read-tool AppleScript fallbacks (`get_email`,
    /// `list_attachments`, …) resolve Gmail / ambiguous-display_name accounts
    /// (#101/#176) instead of failing with `-1728`. The `nil` path stays
    /// byte-identical (locked by `testMsgRef_numericId_byteEquivalencePreserved`).
    func testMsgRef_withAccountId_routesThroughUuidSelector() async {
        let ref = await MailController.shared.msgRef(
            "263385", mailbox: "INBOX", account: "alice@example.com",
            accountId: "ABCD-1234-UUID")
        XCTAssertTrue(ref.contains("account id \"ABCD-1234-UUID\""),
                      "non-empty accountId must select via the UUID form; got:\n\(ref)")
        XCTAssertFalse(ref.contains("account \"alice@example.com\""),
                       "UUID path must NOT also emit the display_name selector; got:\n\(ref)")
        XCTAssertTrue(ref.contains("whose id is 263385"),
                      "message id must still be interpolated")
    }

    /// #180 edge: an explicit empty-string `accountId` is treated as `nil`
    /// (`resolveAccountRef`'s `!isEmpty` guard) — it must NOT emit
    /// `account id ""`, which would `-1728`. Keeps the legacy display_name path
    /// byte-identical.
    func testMsgRef_emptyAccountId_keepsLegacyDisplayNameSelector() async {
        let ref = await MailController.shared.msgRef(
            "42", mailbox: "INBOX", account: "alice@example.com", accountId: "")
        XCTAssertEqual(
            ref,
            "(first message of (first mailbox of account \"alice@example.com\" whose name is \"INBOX\") whose id is 42)",
            "empty accountId must fall back to the legacy display_name selector")
    }
}
