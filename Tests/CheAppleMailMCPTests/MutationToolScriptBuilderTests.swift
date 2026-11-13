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
                                    accountId: uuid, accountName: "alice@example.com", read: true)
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"),
                      "accountId set → UUID selector; got:\n\(s)")
        XCTAssertFalse(s.contains("account \"alice@example.com\""),
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
                                              accountId: "", accountName: "e@f", color: "green")
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

    // MARK: - background color whitelist (#116 — AppleScript injection hardening)
    //
    // `buildSetBackgroundColorScript` accepts an externally-supplied `color: String`
    // and raw-interpolates it into the AppleScript template. Without a whitelist,
    // a malicious or buggy caller passing `color = "red\n        do shell script
    // \"…\""` injects arbitrary AppleScript into osascript. The shared
    // `backgroundColorWhitelist` constant is the single source of truth gating
    // both the handler (Server.swift) and the builder (precondition).
    //
    // The 8 enum values come from Apple Mail's background color set + are
    // duplicated in `Server.swift:467` schema description — these tests pin
    // the constant against drift in both directions.

    func testBackgroundColorWhitelist_containsAllAppleMailEnumValues() {
        let expected: Set<String> = ["blue", "gray", "green", "none",
                                     "orange", "purple", "red", "yellow"]
        XCTAssertEqual(backgroundColorWhitelist, expected,
                       "whitelist must exactly match Apple Mail's documented enum;"
                       + " drift in either direction (missing or extra entries) is a bug")
    }

    func testBackgroundColorWhitelist_rejectsInjectionPayloads() {
        // Newline-based AppleScript verb injection — the original CVE shape
        XCTAssertFalse(
            backgroundColorWhitelist.contains("red\n        do shell script \"rm -rf ~\""),
            "newline-bearing payload must not be a whitelist member")

        // Quote-bearing injection
        XCTAssertFalse(
            backgroundColorWhitelist.contains("red\""),
            "quote-bearing payload must not be a whitelist member")

        // Semicolon / verb chaining
        XCTAssertFalse(
            backgroundColorWhitelist.contains("blue; set foo to evil"),
            "semicolon-chained payload must not be a whitelist member")
    }

    func testBackgroundColorWhitelist_isCaseStrict() {
        // Case-folding would let `"Blue"` / `"BLUE"` through, eroding the
        // schema-description contract (lowercase canonical set).
        XCTAssertFalse(backgroundColorWhitelist.contains("Blue"),
                       "case-variant must be rejected — whitelist is lowercase-strict")
        XCTAssertFalse(backgroundColorWhitelist.contains("BLUE"),
                       "case-variant must be rejected — whitelist is lowercase-strict")
    }

    func testBackgroundColorWhitelist_rejectsTrailingWhitespace() {
        // Whitespace-padded values would also escape AppleScript validation
        // (the trailing-space form parses as a malformed enum reference);
        // the contract is exact-match against the canonical lowercase set.
        XCTAssertFalse(backgroundColorWhitelist.contains("blue "),
                       "trailing-whitespace variant must be rejected")
        XCTAssertFalse(backgroundColorWhitelist.contains(""),
                       "empty string must be rejected (placeholder / lazy-default trap)")
    }

    // MARK: - mark_as_junk reports what it did (#689)
    //
    // The tool set the `junk mail status` property and answered "Email marked as
    // not junk" while the message stayed in the junk mailbox. The property is a
    // flag; it does not move the message. These tests pin the report the caller
    // now gets, and the read-back the script performs.

    private let junkTail = "mark_as_junk changes the flag only: it did not move the message, which was addressed in mailbox"

    func testMarkAsJunkReport_textByReadBack() throws {
        // spec-example: junk-status-tool / report text by read-back
        XCTAssertEqual(
            try markAsJunkReport(requested: false, readBack: .value(false), mailbox: "[Gmail]/垃圾郵件"),
            "Junk mail status is now false. \(junkTail) \"[Gmail]/垃圾郵件\". To move it, call move_email.")
        XCTAssertEqual(
            try markAsJunkReport(requested: true, readBack: .value(true), mailbox: "INBOX"),
            "Junk mail status is now true. \(junkTail) \"INBOX\". To move it, call move_email.")
        XCTAssertEqual(
            try markAsJunkReport(requested: false, readBack: .unknown, mailbox: "INBOX"),
            "Junk mail status was set to false, but it could not be read back. \(junkTail) \"INBOX\". To move it, call move_email.")
    }

    func testMarkAsJunkReport_oppositeReadBackIsAnError() {
        // spec-example: junk-status-tool / opposite read-back
        XCTAssertThrowsError(try markAsJunkReport(requested: false, readBack: .value(true), mailbox: "INBOX")) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Mail still reports junk mail status true after it was set to false. The message was addressed in mailbox \"INBOX\" and was not moved.")
        }
        XCTAssertThrowsError(try markAsJunkReport(requested: true, readBack: .value(false), mailbox: "Junk")) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Mail still reports junk mail status false after it was set to true. The message was addressed in mailbox \"Junk\" and was not moved.")
        }
    }

    func testBuildMarkAsJunkScript_setsThenReadsBackInsideTry() throws {
        // spec-example: junk-status-tool / script shape and output parsing
        let s = buildMarkAsJunkScript(id: "3", mailbox: "INBOX",
                                      accountId: uuid, accountName: "x@y", isJunk: false)
        let set = try XCTUnwrap(s.range(of: "set junk mail status of"))
        let tryStart = try XCTUnwrap(s.range(of: #"\n[ \t]*try\n"#, options: .regularExpression),
                                     "a line that is only `try`, whatever its indentation:\n\(s)")
        let tryEnd = try XCTUnwrap(s.range(of: "end try"))
        let ret = try XCTUnwrap(s.range(of: "return flagNow"))
        XCTAssertTrue(s.contains("to false"))
        XCTAssertLessThan(set.lowerBound, tryStart.lowerBound, "the status is set before it is read back")
        let insideTry = String(s[tryStart.upperBound..<tryEnd.lowerBound])
        XCTAssertTrue(insideTry.contains("junk mail status of"), "the read-back sits inside the try block:\n\(s)")
        XCTAssertTrue(insideTry.contains("(account id \"\(uuid)\")"), "the read-back addresses the same message")
        XCTAssertLessThan(tryEnd.lowerBound, ret.lowerBound, "the script returns after the try block")
        XCTAssertTrue(s.contains("set flagNow to \"unknown\""), "a failed read-back leaves the answer unknown")
        XCTAssertFalse(s.contains("Email marked as"), "the fixed success string is gone")

        XCTAssertEqual(parseJunkStatusReadBack("true"), .value(true))
        XCTAssertEqual(parseJunkStatusReadBack(" false \n"), .value(false))
        XCTAssertEqual(parseJunkStatusReadBack("unknown"), .unknown)
        XCTAssertEqual(parseJunkStatusReadBack(""), .unknown)
        XCTAssertEqual(parseJunkStatusReadBack("maybe"), .unknown)
    }

    func testMarkAsJunk_throughFakeScriptRunner() async throws {
        // spec-example: junk-status-tool / tool result through a fake script runner
        let controller = MailController.shared
        func run(_ output: String) async throws -> String {
            await controller.setTestSeams(scriptRunner: { _ in output }, refusal: nil, scriptTimeout: 5.0)
            return try await controller.markAsJunk(id: "3", mailbox: "INBOX", accountId: nil,
                                                   accountName: "x@y", isJunk: false)
        }
        let same = try await run("false")
        XCTAssertTrue(same.hasPrefix("Junk mail status is now false."), same)
        let unknown = try await run("unknown")
        XCTAssertTrue(unknown.hasPrefix("Junk mail status was set to false, but it could not be read back."), unknown)
        do {
            let wrong = try await run("true")
            XCTFail("an opposite read-back must not be reported as success: \(wrong)")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(text.hasPrefix("Mail still reports junk mail status true"), text)
        }
        await controller.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testMarkAsJunkDescription_saysItChangesTheFlagOnly() throws {
        // spec-example: junk-status-tool / description text
        let tool = try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == "mark_as_junk" })
        let description = try XCTUnwrap(tool.description)
        for needed in ["flag only", "does not move", "move_email"] {
            XCTAssertTrue(description.contains(needed), "missing '\(needed)' in: \(description)")
        }
    }
}
