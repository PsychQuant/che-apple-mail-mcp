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

    // MARK: - #135 escape coverage (SEC-6 from #132 verify)

    /// #135 gap 1: account_id with embedded `"` must be escaped where it
    /// appears in the `(account id "...")` selector. Regression that dropped
    /// `appleScriptEscape` from `msgRefByAccountId` would not be caught by
    /// recipient-only escape tests.
    func testBuildRedirectEmailScript_escapesAccountIdQuotes() {
        let s = buildRedirectEmailScript(
            id: "1", mailbox: "INBOX",
            accountId: "abc\"123", accountName: "alice@example.com",
            to: ["x@y.z"]
        )
        XCTAssertTrue(s.contains("(account id \"abc\\\"123\")"),
                      "accountId quote must be backslash-escaped inside selector; got:\n\(s)")
    }

    /// #135 gap 1: mailbox name with embedded `"` flows into
    /// `whose name is "..."` and must be escaped.
    func testBuildRedirectEmailScript_escapesMailboxQuotes() {
        let s = buildRedirectEmailScript(
            id: "1", mailbox: "Weird\"Folder",
            accountId: nil, accountName: "alice@example.com",
            to: ["x@y.z"]
        )
        XCTAssertTrue(s.contains("whose name is \"Weird\\\"Folder\""),
                      "mailbox name quote must be backslash-escaped; got:\n\(s)")
    }

    /// #135 gap 1: backslash in input is the classic double-escape trap —
    /// `\` must become `\\` BEFORE `"` becomes `\"` (escape-order discipline,
    /// see ComposeScriptBuilder.appleScriptEscape line 5).
    func testBuildRedirectEmailScript_escapesBackslashInRecipient() {
        let s = buildRedirectEmailScript(
            id: "1", mailbox: "INBOX",
            accountId: nil, accountName: "alice@example.com",
            to: ["weird\\@example.com"]
        )
        // Single backslash in input → `\\` in script (AppleScript string-literal
        // escape). The recipient line should contain `weird\\@example.com`.
        XCTAssertTrue(s.contains("weird\\\\@example.com"),
                      "backslash in recipient must be doubled; got:\n\(s)")
    }

    /// #135 gap 1: account_name with embedded `\` in the display_name
    /// fallback path. Mirrors backslash-recipient discipline at the account
    /// selector position.
    func testBuildRedirectEmailScript_escapesBackslashInAccountName() {
        let s = buildRedirectEmailScript(
            id: "1", mailbox: "INBOX",
            accountId: nil, accountName: "weird\\name",
            to: ["x@y.z"]
        )
        XCTAssertTrue(s.contains("account \"weird\\\\name\""),
                      "backslash in accountName must be doubled; got:\n\(s)")
    }

    // MARK: - #135 byte-identity golden-string fixture (DA-4 residual)

    /// #135 gap 2: pin the entire `buildRedirectEmailScript(accountId: nil,
    /// ...)` output to a hardcoded expected string. PR #132 verified
    /// byte-identity by 3 reviewers manually compiling-and-diffing during
    /// verify, but no automated test guards against silent drift (e.g. if
    /// `appleScriptEscape` and `MailController.escapeForAppleScript` ever
    /// diverged again before #110 dedup, or if any helper between layers
    /// changes whitespace/indent semantics).
    func testBuildRedirectEmailScript_displayNameFallback_byteIdentityGolden() {
        let s = buildRedirectEmailScript(
            id: "42", mailbox: "INBOX",
            accountId: nil, accountName: "alice@example.com",
            to: ["x@example.com"]
        )
        // Golden string built via concatenation to make indent levels
        // explicit. Builder emits `make new to recipient` at 4-space indent
        // (RedirectEmailScriptBuilder.swift line 35-37 uses `""" make new...`
        // with closing quote at 8 spaces → 4 columns of preserved indent).
        let expected =
            "tell application \"Mail\"\n" +
            "    set originalMsg to (first message of (first mailbox of account \"alice@example.com\" whose name is \"INBOX\") whose id is 42)\n" +
            "    set redirectMsg to redirect originalMsg with opening window\n" +
            "    tell redirectMsg\n" +
            "    make new to recipient at end of to recipients with properties {address:\"x@example.com\"}\n" +
            "    end tell\n" +
            "    send redirectMsg\n" +
            "    return \"Email redirected successfully\"\n" +
            "end tell"
        XCTAssertEqual(s, expected,
                       "byte-identity drift; got:\n\(s)\n\nexpected:\n\(expected)")
    }
}
