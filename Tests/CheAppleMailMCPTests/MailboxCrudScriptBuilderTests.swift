import XCTest
@testable import CheAppleMailMCP

/// Tests for the 2 mailbox-CRUD script builders (#104 PR-D — final sweep increment).
///
/// `create_mailbox` and `delete_mailbox` use DIFFERENT ref shapes:
/// - `buildCreateMailboxScript` addresses an account directly (`make new
///   mailbox ... at <accountRef>`) — uses the new `resolveAccountRef`.
/// - `buildDeleteMailboxScript` references an existing mailbox (`delete
///   <mailboxRef>`) — uses the existing `resolveMailboxRef` chokepoint.
final class MailboxCrudScriptBuilderTests: XCTestCase {

    private let uuid = "C38E0583-47F8-4468-BE70-43155C15549D"

    // MARK: - create_mailbox (account-only ref)

    func testBuildCreateMailboxScript_uuidPath_usesAccountIdSelector() {
        let s = buildCreateMailboxScript(
            name: "Archive", accountId: uuid, accountName: "alice@example.com"
        )
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"),
                      "UUID path must address the account via (account id \"...\"); got:\n\(s)")
        XCTAssertFalse(s.contains("account \"alice@example.com\""),
                       "display_name must not leak in UUID path")
        XCTAssertTrue(s.contains("make new mailbox"), "must contain the create verb")
        XCTAssertTrue(s.contains("name:\"Archive\""), "new mailbox name must appear")
    }

    func testBuildCreateMailboxScript_displayNameFallback() {
        let s = buildCreateMailboxScript(
            name: "Archive", accountId: nil, accountName: "alice@example.com"
        )
        XCTAssertTrue(s.contains("at account \"alice@example.com\""),
                      "nil accountId must fall back to the legacy account \"<display_name>\" selector")
        XCTAssertFalse(s.contains("(account id"), "UUID form must not appear in fallback path")
        XCTAssertTrue(s.contains("make new mailbox"))
    }

    func testBuildCreateMailboxScript_emptyStringAccountId_fallsBackLikeNil() {
        let s = buildCreateMailboxScript(
            name: "Archive", accountId: "", accountName: "bob@example.com"
        )
        XCTAssertTrue(s.contains("at account \"bob@example.com\""))
        XCTAssertFalse(s.contains("(account id"))
    }

    func testBuildCreateMailboxScript_escapesMailboxNameQuotes() {
        let s = buildCreateMailboxScript(
            name: "My\"Box", accountId: nil, accountName: "bob@example.com"
        )
        XCTAssertTrue(s.contains("My\\\"Box"), "quote in mailbox name must be backslash-escaped")
    }

    // MARK: - delete_mailbox (existing-mailbox ref via resolveMailboxRef)

    func testBuildDeleteMailboxScript_uuidPath_usesAccountIdSelector() {
        let s = buildDeleteMailboxScript(
            name: "Old Folder", accountId: uuid, accountName: "alice@example.com"
        )
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"),
                      "UUID path must emit the (account id \"...\") selector; got:\n\(s)")
        XCTAssertFalse(s.contains("account \"alice@example.com\""),
                       "display_name must not leak in UUID path")
        XCTAssertTrue(s.contains("whose name is \"Old Folder\""),
                      "mailboxRef must reference the target mailbox by name")
        // Strong verb assertion: anchor on `delete (first mailbox` — NOT a bare
        // "delete" substring, since the return string "Deleted mailbox:" also
        // contains "delete" (the #128/DA-5 trap).
        XCTAssertTrue(s.contains("delete (first mailbox"), "must contain the delete verb")
    }

    func testBuildDeleteMailboxScript_displayNameFallback() {
        let s = buildDeleteMailboxScript(
            name: "Old Folder", accountId: nil, accountName: "alice@example.com"
        )
        XCTAssertTrue(s.contains("account \"alice@example.com\""),
                      "nil accountId must fall back to the display_name selector")
        XCTAssertFalse(s.contains("(account id"), "UUID form must not appear in fallback path")
        XCTAssertTrue(s.contains("delete (first mailbox"))
    }

    func testBuildDeleteMailboxScript_emptyStringAccountId_fallsBackLikeNil() {
        let s = buildDeleteMailboxScript(
            name: "Old Folder", accountId: "", accountName: "bob@example.com"
        )
        XCTAssertTrue(s.contains("account \"bob@example.com\""))
        XCTAssertFalse(s.contains("(account id"))
    }
}
