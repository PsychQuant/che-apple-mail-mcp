import XCTest
@testable import CheAppleMailMCP

/// Tests for the 3 movement/destruction script builders (#104 PR-B).
///
/// `move_email` + `copy_email` emit TWO refs (source `msgRef` + destination
/// `mailboxRef`) in a single script — UUID-path tests assert BOTH refs use
/// `(account id "<UUID>")`. `delete_email` has only one ref (single-mailbox
/// mutation), matching PR-A's single-ref pattern.
final class MoveCopyDeleteScriptBuilderTests: XCTestCase {

    private let uuid = "C38E0583-47F8-4468-BE70-43155C15549D"

    // MARK: - move_email (TWO refs: source + destination)

    func testBuildMoveEmailScript_uuidPath_bothRefsUseUuid() {
        let s = buildMoveEmailScript(
            id: "42", fromMailbox: "INBOX", toMailbox: "Archive",
            accountId: uuid, accountName: "alice@example.com"
        )
        // Source ref (msgRef) — UUID
        XCTAssertTrue(s.contains("whose id is 42"),
                      "source msgRef must include numeric id; got:\n\(s)")
        // Destination ref (mailboxRef) — UUID
        let uuidSelectorCount = s.components(separatedBy: "(account id \"\(uuid)\")").count - 1
        XCTAssertEqual(uuidSelectorCount, 2,
                       "expected UUID selector to appear TWICE (source + destination); got \(uuidSelectorCount) in:\n\(s)")
        XCTAssertFalse(s.contains("account \"alice@example.com\""),
                       "display_name must not leak in UUID path")
        XCTAssertTrue(s.contains("move msg to"), "must contain move verb")
        XCTAssertTrue(s.contains("whose name is \"Archive\""), "destination mailbox name must appear")
    }

    func testBuildMoveEmailScript_displayNameFallback() {
        let s = buildMoveEmailScript(
            id: "42", fromMailbox: "INBOX", toMailbox: "Archive",
            accountId: nil, accountName: "alice@example.com"
        )
        // Both refs fall back to display_name form
        let displayNameSelectorCount = s.components(separatedBy: "account \"alice@example.com\"").count - 1
        XCTAssertEqual(displayNameSelectorCount, 2,
                       "expected display_name to appear TWICE (source + destination); got \(displayNameSelectorCount) in:\n\(s)")
        XCTAssertFalse(s.contains("(account id"), "UUID form must not appear in fallback path")
        XCTAssertTrue(s.contains("move msg to"))
        XCTAssertTrue(s.contains("whose name is \"Archive\""))
    }

    // MARK: - copy_email (TWO refs: source + destination, uses `duplicate` verb)

    func testBuildCopyEmailScript_uuidPath_bothRefsUseUuid() {
        let s = buildCopyEmailScript(
            id: "99", fromMailbox: "Drafts", toMailbox: "Sent",
            accountId: uuid, accountName: "bob@example.com"
        )
        XCTAssertTrue(s.contains("whose id is 99"))
        let uuidSelectorCount = s.components(separatedBy: "(account id \"\(uuid)\")").count - 1
        XCTAssertEqual(uuidSelectorCount, 2,
                       "expected UUID selector to appear TWICE; got \(uuidSelectorCount) in:\n\(s)")
        XCTAssertFalse(s.contains("account \"bob@example.com\""))
        XCTAssertTrue(s.contains("duplicate msg to"), "copy uses duplicate verb")
        XCTAssertTrue(s.contains("whose name is \"Sent\""))
    }

    func testBuildCopyEmailScript_displayNameFallback() {
        let s = buildCopyEmailScript(
            id: "99", fromMailbox: "Drafts", toMailbox: "Sent",
            accountId: "", accountName: "carol@example.com"
        )
        // Empty-string accountId should fall back same as nil (resolver semantic)
        let displayNameSelectorCount = s.components(separatedBy: "account \"carol@example.com\"").count - 1
        XCTAssertEqual(displayNameSelectorCount, 2)
        XCTAssertFalse(s.contains("(account id"))
        XCTAssertTrue(s.contains("duplicate msg to"))
    }

    // MARK: - delete_email (ONE ref, like PR-A's single-mailbox tools)

    func testBuildDeleteEmailScript_uuidPath() {
        let s = buildDeleteEmailScript(
            id: "7", mailbox: "Junk",
            accountId: uuid, accountName: "dan@example.com"
        )
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"))
        XCTAssertFalse(s.contains("account \"dan@example.com\""),
                       "display_name must not appear in UUID path")
        // #128: anchor on the verb form, NOT the substring "delete". The
        // script ends with `return "Email deleted"`, so a substring check
        // on "delete" was trivially true even if the actual `delete <ref>`
        // verb was removed or swapped for `move msg to trash`. Verb form
        // is `\n    delete (` — leading indent + verb + space + opening
        // paren of the ref expression.
        XCTAssertTrue(s.contains("\n    delete ("),
                      "must emit the AppleScript `delete <ref>` verb at the action line")
        XCTAssertTrue(s.contains("whose id is 7"))
        // delete_email is a SINGLE-ref operation — exactly one
        // `(account id "<UUID>")` selector must appear (no accidental
        // destination ref emission).
        let accountSelectorCount = s.components(separatedBy: "(account id \"").count - 1
        XCTAssertEqual(accountSelectorCount, 1,
                       "delete_email is single-ref — exactly one account selector expected")
    }

    func testBuildDeleteEmailScript_displayNameFallback() {
        let s = buildDeleteEmailScript(
            id: "7", mailbox: "Junk",
            accountId: nil, accountName: "eve@example.com"
        )
        XCTAssertTrue(s.contains("account \"eve@example.com\""))
        XCTAssertFalse(s.contains("(account id"))
        // #128: anchor on verb form (see UUID path test above).
        XCTAssertTrue(s.contains("\n    delete ("),
                      "must emit the AppleScript `delete <ref>` verb at the action line")
        // Single-ref shape: exactly one `account "<display_name>"` selector.
        let displayNameSelectorCount = s.components(separatedBy: "account \"eve@example.com\"").count - 1
        XCTAssertEqual(displayNameSelectorCount, 1,
                       "delete_email is single-ref — exactly one account selector expected")
    }
}
