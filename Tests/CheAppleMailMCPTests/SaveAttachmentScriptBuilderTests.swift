import XCTest
@testable import CheAppleMailMCP

/// Tests for `buildSaveAttachmentScript` + related helpers added for #101.
///
/// Verifies that:
/// 1. `mailboxRefByAccountId` produces `(first mailbox of (account id "X")
///    whose name is "Y")` — the Phase 0-verified AppleScript form
/// 2. `msgRefByAccountId` chains the mailbox ref by message ROWID
/// 3. `buildSaveAttachmentScript` picks the UUID path when `accountId`
///    is non-nil, falls back to display_name path when nil/empty
/// 4. AppleScript escaping flows through (quotes, control chars)
final class SaveAttachmentScriptBuilderTests: XCTestCase {

    // MARK: - mailboxRefByAccountId

    func testMailboxRefByAccountId_emitsAccountIdSelector() {
        let ref = mailboxRefByAccountId("INBOX", accountId: "C38E0583-47F8-4468-BE70-43155C15549D")
        XCTAssertEqual(
            ref,
            "(first mailbox of (account id \"C38E0583-47F8-4468-BE70-43155C15549D\") whose name is \"INBOX\")",
            "mailboxRefByAccountId MUST use the (account id \"...\") selector — "
            + "this is the Phase 0-verified AppleScript syntax that resolves Mail.app's "
            + "globally-unique account UUID without falling back to display_name collision."
        )
    }

    func testMailboxRefByAccountId_escapesQuotesInMailboxName() {
        // Gmail-style mailbox with localized name '寄件備份' is fine; but if a
        // mailbox name ever contains literal quotes the AppleScript escape must run.
        let ref = mailboxRefByAccountId("Has\"Quote", accountId: "UUID-X")
        XCTAssertTrue(ref.contains("\\\"Quote"),
                      "Quote in mailbox name MUST be backslash-escaped: \(ref)")
    }

    // MARK: - msgRefByAccountId

    func testMsgRefByAccountId_chainsRowId() {
        let ref = msgRefByAccountId("42", mailbox: "INBOX", accountId: "UUID-A")
        XCTAssertEqual(
            ref,
            "(first message of (first mailbox of (account id \"UUID-A\") whose name is \"INBOX\") whose id is 42)",
            "msgRefByAccountId must compose mailbox ref + 'whose id is <ROWID>' "
            + "without quotes around the numeric id (Apple Mail's `id` is internal int)"
        )
    }

    // MARK: - buildSaveAttachmentScript (UUID path)

    func testBuildSaveAttachmentScript_withAccountId_usesUuidPath() {
        let script = buildSaveAttachmentScript(
            id: "263385",
            mailbox: "收件匣",
            accountId: "C38E0583-47F8-4468-BE70-43155C15549D",
            accountName: "kiki830621@gmail.com",   // ambiguous display_name — should NOT appear
            attachmentName: "test.pdf",
            savePath: "/tmp/test.pdf"
        )

        XCTAssertTrue(
            script.contains("(account id \"C38E0583-47F8-4468-BE70-43155C15549D\")"),
            "UUID path MUST use (account id \"...\") selector; got:\n\(script)"
        )
        XCTAssertFalse(
            script.contains("account \"kiki830621@gmail.com\""),
            "When accountId is provided, the display_name (ambiguous) MUST NOT "
            + "appear in the AppleScript — that defeats disambiguation. Got:\n\(script)"
        )
        XCTAssertTrue(script.contains("whose id is 263385"),
                      "Script must reference the message ROWID")
        XCTAssertTrue(script.contains("save att in POSIX file \"/tmp/test.pdf\""),
                      "Script must save to the requested POSIX path")
        XCTAssertTrue(script.contains("if name of att is \"test.pdf\""),
                      "Script must match attachment by name")
    }

    // MARK: - buildSaveAttachmentScript (legacy fallback path)

    func testBuildSaveAttachmentScript_withNilAccountId_fallsBackToDisplayName() {
        let script = buildSaveAttachmentScript(
            id: "263385",
            mailbox: "INBOX",
            accountId: nil,
            accountName: "kiki830621@gmail.com",
            attachmentName: "test.pdf",
            savePath: "/tmp/test.pdf"
        )
        XCTAssertTrue(
            script.contains("account \"kiki830621@gmail.com\""),
            "When accountId is nil, fall back to the legacy account \"<display_name>\" "
            + "form for backward compat. Got:\n\(script)"
        )
        XCTAssertFalse(
            script.contains("account id "),
            "Legacy fallback MUST NOT use account id selector. Got:\n\(script)"
        )
    }

    func testBuildSaveAttachmentScript_withEmptyAccountId_fallsBackToDisplayName() {
        // Defensive: empty-string accountId should be treated same as nil
        // (avoid emitting `account id ""` which would always fail).
        let script = buildSaveAttachmentScript(
            id: "1",
            mailbox: "INBOX",
            accountId: "",
            accountName: "alice@example.com",
            attachmentName: "f.pdf",
            savePath: "/tmp/f.pdf"
        )
        XCTAssertTrue(
            script.contains("account \"alice@example.com\""),
            "Empty accountId MUST be treated as nil (fall back to display_name); got:\n\(script)"
        )
        XCTAssertFalse(script.contains("account id \"\""),
                       "Empty accountId MUST NOT produce account id \"\" — that's an invalid selector")
    }

    // MARK: - AppleScript escaping flows through

    func testBuildSaveAttachmentScript_escapesQuotesInPath() {
        let script = buildSaveAttachmentScript(
            id: "1",
            mailbox: "INBOX",
            accountId: "UUID-X",
            accountName: "alice@example.com",
            attachmentName: "file.pdf",
            savePath: "/tmp/has\"quote.pdf"
        )
        // appleScriptEscape converts " to \" so the script contains \\\\"" in the
        // Swift literal, which is a single backslash + quote in the actual string.
        XCTAssertTrue(script.contains("has\\\"quote.pdf"),
                      "Save path with quote must be escaped; got:\n\(script)")
    }
}
