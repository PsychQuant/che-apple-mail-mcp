import XCTest
@testable import CheAppleMailMCP

/// Tests for `buildRedirectEmailScript` (#104 PR-C).
///
/// `redirect_email` is a single-ref tool (one `msgRef` to the message being
/// redirected) — matching the PR-A single-ref pattern. Before PR-C the script
/// was built inline in `MailController.redirectEmail`; PR-C extracts it into a
/// free builder so the `account_id` UUID path is unit-testable, mirroring PR-B's
/// `MoveCopyDeleteScriptBuilder`.
final class RedirectEmailScriptBuilderTests: XCTestCase {

    private let uuid = "C38E0583-47F8-4468-BE70-43155C15549D"

    func testBuildRedirectEmailScript_uuidPath_usesAccountIdSelector() {
        let s = buildRedirectEmailScript(
            id: "42", mailbox: "INBOX",
            accountId: uuid, accountName: "alice@example.com",
            to: ["forward-to@example.com"]
        )
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"),
                      "UUID path must emit the (account id \"...\") selector; got:\n\(s)")
        XCTAssertFalse(s.contains("account \"alice@example.com\""),
                       "display_name must not leak in UUID path")
        XCTAssertTrue(s.contains("whose id is 42"), "msgRef must include the numeric id")
        // Strong verb assertion: anchor on `redirect originalMsg`, NOT a bare
        // "redirect" substring — the script also contains the return string
        // "Email redirected successfully" (same trap as #128/DA-5).
        XCTAssertTrue(s.contains("redirect originalMsg"), "must contain the redirect verb")
        XCTAssertTrue(s.contains("address:\"forward-to@example.com\""),
                      "recipient address must appear")
    }

    func testBuildRedirectEmailScript_displayNameFallback() {
        let s = buildRedirectEmailScript(
            id: "42", mailbox: "INBOX",
            accountId: nil, accountName: "alice@example.com",
            to: ["forward-to@example.com"]
        )
        XCTAssertTrue(s.contains("account \"alice@example.com\""),
                      "nil accountId must fall back to the display_name selector")
        XCTAssertFalse(s.contains("(account id"), "UUID form must not appear in fallback path")
        XCTAssertTrue(s.contains("redirect originalMsg"))
    }

    func testBuildRedirectEmailScript_emptyStringAccountId_fallsBackLikeNil() {
        // Empty-string accountId must fall back identically to nil (resolver
        // semantic — `resolveMsgRef` guards with `!aid.isEmpty`).
        let s = buildRedirectEmailScript(
            id: "7", mailbox: "INBOX",
            accountId: "", accountName: "bob@example.com",
            to: ["x@example.com"]
        )
        XCTAssertTrue(s.contains("account \"bob@example.com\""))
        XCTAssertFalse(s.contains("(account id"))
    }

    func testBuildRedirectEmailScript_multipleRecipients_emitsEachAddress() {
        let s = buildRedirectEmailScript(
            id: "7", mailbox: "INBOX",
            accountId: nil, accountName: "bob@example.com",
            to: ["a@example.com", "b@example.com", "c@example.com"]
        )
        XCTAssertTrue(s.contains("address:\"a@example.com\""))
        XCTAssertTrue(s.contains("address:\"b@example.com\""))
        XCTAssertTrue(s.contains("address:\"c@example.com\""))
        let recipientCount = s.components(separatedBy: "make new to recipient").count - 1
        XCTAssertEqual(recipientCount, 3, "one `make new to recipient` per address")
    }

    func testBuildRedirectEmailScript_escapesRecipientQuotes() {
        // A recipient containing a double-quote must be escaped so it cannot
        // break out of the AppleScript string literal.
        let s = buildRedirectEmailScript(
            id: "7", mailbox: "INBOX",
            accountId: nil, accountName: "bob@example.com",
            to: ["evil\"name@example.com"]
        )
        XCTAssertTrue(s.contains("evil\\\"name@example.com"),
                      "recipient quote must be backslash-escaped")
    }
}
