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
        let ref = await MailController.shared.msgRef(
            "263385", mailbox: "INBOX", account: "alice@example.com")
        XCTAssertEqual(
            ref,
            "(first message of (first mailbox of account \"alice@example.com\" whose name is \"INBOX\") whose id is 263385)"
        )
    }
}
