import XCTest
@testable import CheAppleMailMCP

/// Tests for the 5 single-message mutation tool script builders (#104 PR-A).
///
/// Each builder delegates account resolution to `resolveMsgRef` — so these
/// tests focus on: (1) the UUID path emits `(account id "...")` when
/// `accountId` is set, (2) the nil path falls back to `account "<display_name>"`,
/// (3) the tool-specific operation line is correct.
final class MutationToolScriptBuilderTests: XCTestCase {

    private let uuid = "C38E0583-47F8-4468-BE70-43155C15549D"

    // MARK: - mark_read

    func testBuildMarkReadScript_uuidPath() {
        let s = buildMarkReadScript(id: "42", mailbox: "INBOX",
                                    accountId: uuid, accountName: "kiki830621@gmail.com", read: true)
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"),
                      "accountId set → UUID selector; got:\n\(s)")
        XCTAssertFalse(s.contains("account \"kiki830621@gmail.com\""),
                       "display_name must not appear in UUID path")
        XCTAssertTrue(s.contains("set read status of") && s.contains("to true"))
    }

    func testBuildMarkReadScript_displayNameFallback() {
        let s = buildMarkReadScript(id: "42", mailbox: "INBOX",
                                    accountId: nil, accountName: "alice@example.com", read: false)
        XCTAssertTrue(s.contains("account \"alice@example.com\""),
                      "nil accountId → legacy display_name form")
        XCTAssertFalse(s.contains("account id "))
        XCTAssertTrue(s.contains("set read status of") && s.contains("to false"))
    }

    // MARK: - flag_email

    func testBuildFlagEmailScript_uuidPath() {
        let s = buildFlagEmailScript(id: "7", mailbox: "INBOX",
                                     accountId: uuid, accountName: "x@y", flagged: true)
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"))
        XCTAssertTrue(s.contains("set flagged status of") && s.contains("to true"))
    }

    func testBuildFlagEmailScript_displayNameFallback() {
        let s = buildFlagEmailScript(id: "7", mailbox: "INBOX",
                                     accountId: "", accountName: "bob@example.com", flagged: false)
        XCTAssertTrue(s.contains("account \"bob@example.com\""),
                      "empty accountId treated as nil")
        XCTAssertFalse(s.contains("account id "))
    }

    // MARK: - set_flag_color

    func testBuildSetFlagColorScript_uuidPath() {
        let s = buildSetFlagColorScript(id: "9", mailbox: "INBOX",
                                        accountId: uuid, accountName: "x@y", colorIndex: 3)
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"))
        XCTAssertTrue(s.contains("set flag index of") && s.contains("to 3"))
    }

    func testBuildSetFlagColorScript_displayNameFallback() {
        let s = buildSetFlagColorScript(id: "9", mailbox: "INBOX",
                                        accountId: nil, accountName: "c@d", colorIndex: 0)
        XCTAssertTrue(s.contains("account \"c@d\""))
        XCTAssertFalse(s.contains("account id "))
    }

    // MARK: - set_background_color

    func testBuildSetBackgroundColorScript_uuidPath() {
        let s = buildSetBackgroundColorScript(id: "5", mailbox: "INBOX",
                                              accountId: uuid, accountName: "x@y", color: "blue")
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"))
        XCTAssertTrue(s.contains("set background color of") && s.contains("to blue"))
    }

    func testBuildSetBackgroundColorScript_displayNameFallback() {
        let s = buildSetBackgroundColorScript(id: "5", mailbox: "INBOX",
                                              accountId: nil, accountName: "e@f", color: "green")
        XCTAssertTrue(s.contains("account \"e@f\""))
        XCTAssertFalse(s.contains("account id "))
    }

    // MARK: - mark_as_junk

    func testBuildMarkAsJunkScript_uuidPath() {
        let s = buildMarkAsJunkScript(id: "3", mailbox: "INBOX",
                                      accountId: uuid, accountName: "x@y", isJunk: true)
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"))
        XCTAssertTrue(s.contains("set junk mail status of") && s.contains("to true"))
    }

    func testBuildMarkAsJunkScript_displayNameFallback() {
        let s = buildMarkAsJunkScript(id: "3", mailbox: "INBOX",
                                      accountId: nil, accountName: "g@h", isJunk: false)
        XCTAssertTrue(s.contains("account \"g@h\""))
        XCTAssertFalse(s.contains("account id "))
    }
}
