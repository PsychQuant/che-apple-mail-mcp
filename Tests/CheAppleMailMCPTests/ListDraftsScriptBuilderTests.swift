import XCTest
@testable import CheAppleMailMCP

/// Tests for `buildListDraftsScript` (#174) — per-account drafts resolution
/// via the unified `drafts mailbox`'s per-account child mailboxes.
///
/// Why this shape (empirically verified 2026-06-11, issue #174 plan):
/// - `drafts mailbox of (account id "...")` does NOT exist (-1728), so the
///   per-account special property is not an option.
/// - `every mailbox of drafts mailbox` returns one child per account, and
///   each child's `account` property resolves — `id of account of mb` is a
///   localization- and provider-independent match key (iCloud "Drafts" and
///   Gmail "草稿" both resolve through the same loop).
///
/// The pre-#174 implementation hardcoded `whose name is "Drafts"`, which can
/// never match a Gmail account's localized drafts mailbox (-1719).
final class ListDraftsScriptBuilderTests: XCTestCase {

    // MARK: - UUID mode

    func testUuidMode_matchesByAccountId() {
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("every mailbox of drafts mailbox"),
                      "Must enumerate the unified drafts mailbox's per-account children")
        XCTAssertTrue(script.contains("(id of account of mb) is \"UUID-A\""),
                      "UUID mode must match children by account id; got:\n\(script)")
        XCTAssertFalse(script.contains("name of account of mb"),
                       "UUID mode must not fall back to account-name matching")
        XCTAssertFalse(script.contains("Google"),
                       "account_name must not leak into the UUID-mode script")
    }

    // MARK: - Name mode (legacy fallback)

    func testNameMode_matchesByAccountName() {
        let script = buildListDraftsScript(accountId: nil, accountName: "Google")
        XCTAssertTrue(script.contains("(name of account of mb) is \"Google\""),
                      "Name mode must match children by Mail's AppleScript account name; got:\n\(script)")
        XCTAssertFalse(script.contains("id of account of mb"),
                       "Name mode must not emit the UUID selector")
    }

    func testEmptyAccountId_treatedAsNameMode() {
        let script = buildListDraftsScript(accountId: "", accountName: "Google")
        XCTAssertTrue(script.contains("(name of account of mb) is \"Google\""),
                      "Empty accountId must behave like nil (name mode)")
    }

    // MARK: - No hardcoded special-mailbox name (#174 core regression lock)

    func testNoHardcodedDraftsLiteral() {
        for script in [
            buildListDraftsScript(accountId: "UUID-A", accountName: "Google"),
            buildListDraftsScript(accountId: nil, accountName: "Google"),
        ] {
            XCTAssertFalse(script.contains("whose name is \"Drafts\""),
                           "The hardcoded Drafts-by-name lookup must be gone; got:\n\(script)")
        }
    }

    // MARK: - Returns subjects + no-match error contract

    func testReturnsSubjectsOfMatchedMailbox() {
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("return subject of messages of mb"),
                      "Matched child must return its messages' subjects; got:\n\(script)")
    }

    func testNoMatchRaisesRecognizableErrorNumber() {
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("number 9174"),
                      "No-match must raise the recognizable custom error number 9174 "
                      + "so MailController can translate it into an actionable message; got:\n\(script)")
    }

    // MARK: - Escaping

    func testEscapesQuotes_inBothModes() {
        let uuidMode = buildListDraftsScript(accountId: "uuid\"x", accountName: "a")
        XCTAssertTrue(uuidMode.contains("uuid\\\"x"),
                      "Quote in accountId must be escaped")
        let nameMode = buildListDraftsScript(accountId: nil, accountName: "has\"quote")
        XCTAssertTrue(nameMode.contains("has\\\"quote"),
                      "Quote in accountName must be escaped")
    }
}
