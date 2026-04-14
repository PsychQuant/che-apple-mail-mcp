import XCTest
@testable import CheAppleMailMCP

final class AccountsScriptParserTests: XCTestCase {

    // Convenience constants for readability in test fixtures.
    private let RS = "\u{001E}"
    private let US = "\u{001F}"
    private let GS = "\u{001D}"

    // MARK: - parse

    func testParsesSingleImapAccount() {
        let raw = [
            "Gmail",
            "kiki830621@gmail.com",
            "C38E0583-47F8-4468-BE70-43155C15549D",
            "kiki830621@gmail.com",
            "true"
        ].joined(separator: US)

        let accounts = AccountsScriptParser.parse(raw)

        XCTAssertEqual(accounts.count, 1)
        let acc = accounts[0]
        XCTAssertEqual(acc.name, "Gmail")
        XCTAssertEqual(acc.userName, "kiki830621@gmail.com")
        XCTAssertEqual(acc.id, "C38E0583-47F8-4468-BE70-43155C15549D")
        XCTAssertEqual(acc.emailAddresses, ["kiki830621@gmail.com"])
        XCTAssertEqual(acc.displayName, "kiki830621@gmail.com")
        XCTAssertTrue(acc.enabled)
    }

    func testParsesEwsAccountWithUrlName() {
        let ewsURL = "ews://AAMkAGE5MTZiZmU5LTAwOTMtNDM5NS1iMDY0LTJiMzRiMDMyYmVkNQ==/"
        let raw = [
            ewsURL,
            "d06227105@ntu.edu.tw",
            "ABCE3A85-06BE-43BC-9B84-2CA6F325612F",
            "d06227105@ntu.edu.tw",
            "true"
        ].joined(separator: US)

        let accounts = AccountsScriptParser.parse(raw)

        XCTAssertEqual(accounts.count, 1)
        let acc = accounts[0]
        // The raw `name` attribute is still the AccountURL (Mail.app returns it).
        XCTAssertEqual(acc.name, ewsURL)
        // But `display_name` should be the usable email, not the URL.
        XCTAssertEqual(acc.displayName, "d06227105@ntu.edu.tw")
        XCTAssertEqual(acc.userName, "d06227105@ntu.edu.tw")
        XCTAssertFalse(
            acc.displayName.hasPrefix("ews://"),
            "display_name must not leak the ews:// URL"
        )
    }

    func testParsesMultipleAccountsImapPlusEws() {
        let imapRecord = [
            "kiki830621@gmail.com",   // name
            "kiki830621@gmail.com",   // user_name
            "C38E0583-47F8-4468-BE70-43155C15549D",
            "kiki830621@gmail.com",   // email_addresses (single)
            "true"
        ].joined(separator: US)

        let ewsRecord = [
            "ews://AAMkA.../",
            "d06227105@ntu.edu.tw",
            "ABCE3A85-06BE-43BC-9B84-2CA6F325612F",
            "d06227105@ntu.edu.tw",
            "true"
        ].joined(separator: US)

        let raw = [imapRecord, ewsRecord].joined(separator: RS)

        let accounts = AccountsScriptParser.parse(raw)

        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].displayName, "kiki830621@gmail.com")
        XCTAssertEqual(accounts[1].displayName, "d06227105@ntu.edu.tw")
        // Sanity: neither display_name should be a URL.
        for acc in accounts {
            XCTAssertFalse(acc.displayName.hasPrefix("ews://"))
            XCTAssertFalse(acc.displayName.hasPrefix("imap://"))
        }
    }

    func testMultipleEmailAddressesSplitByGroupSeparator() {
        let raw = [
            "Work",
            "primary@example.com",
            "UUID-123",
            "primary@example.com\(GS)alias1@example.com\(GS)alias2@example.com",
            "true"
        ].joined(separator: US)

        let accounts = AccountsScriptParser.parse(raw)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].emailAddresses, [
            "primary@example.com",
            "alias1@example.com",
            "alias2@example.com"
        ])
    }

    // MARK: - display_name fallback rule

    func testDisplayNameFallsBackToEmailAddressesWhenUserNameMissing() {
        let raw = [
            "Gmail",
            "",  // empty user_name
            "UUID-1",
            "fallback@example.com",
            "true"
        ].joined(separator: US)

        let accounts = AccountsScriptParser.parse(raw)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertNil(accounts[0].userName)
        XCTAssertEqual(accounts[0].displayName, "fallback@example.com")
    }

    func testDisplayNameFallsBackToNameWhenBothUserNameAndEmailsMissing() {
        let raw = [
            "Some Account",
            "",  // empty user_name
            "UUID-1",
            "",  // empty email_addresses
            "true"
        ].joined(separator: US)

        let accounts = AccountsScriptParser.parse(raw)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].displayName, "Some Account")
    }

    // MARK: - Malformed input

    func testEmptyInputReturnsEmptyArray() {
        XCTAssertEqual(AccountsScriptParser.parse("").count, 0)
        XCTAssertEqual(AccountsScriptParser.parse("   \n\t  ").count, 0)
    }

    func testRecordWithWrongFieldCountIsSkipped() {
        // Only 3 fields instead of 5
        let raw = ["Gmail", "user", "UUID"].joined(separator: US)
        XCTAssertEqual(AccountsScriptParser.parse(raw).count, 0)
    }

    func testRecordWithEmptyIdIsSkipped() {
        let raw = [
            "Gmail",
            "user",
            "",  // empty id
            "",
            "true"
        ].joined(separator: US)
        XCTAssertEqual(AccountsScriptParser.parse(raw).count, 0)
    }

    func testPartialFailureDoesNotDropValidRecords() {
        let validRecord = [
            "Gmail",
            "user@example.com",
            "UUID-1",
            "user@example.com",
            "true"
        ].joined(separator: US)

        let brokenRecord = "only-one-field"

        let anotherValid = [
            "Work",
            "work@example.com",
            "UUID-2",
            "work@example.com",
            "false"
        ].joined(separator: US)

        let raw = [validRecord, brokenRecord, anotherValid].joined(separator: RS)

        let accounts = AccountsScriptParser.parse(raw)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].id, "UUID-1")
        XCTAssertEqual(accounts[0].enabled, true)
        XCTAssertEqual(accounts[1].id, "UUID-2")
        XCTAssertEqual(accounts[1].enabled, false)
    }

    // MARK: - asDictionary

    func testAsDictionaryExposesAllFields() {
        let acc = AccountInfo(
            name: "ews://AAMkA.../",
            userName: "d06227105@ntu.edu.tw",
            id: "UUID-EWS",
            emailAddresses: ["d06227105@ntu.edu.tw"],
            enabled: true
        )

        let dict = acc.asDictionary()

        XCTAssertEqual(dict["name"] as? String, "ews://AAMkA.../")
        XCTAssertEqual(dict["user_name"] as? String, "d06227105@ntu.edu.tw")
        XCTAssertEqual(dict["id"] as? String, "UUID-EWS")
        XCTAssertEqual(dict["email_addresses"] as? [String], ["d06227105@ntu.edu.tw"])
        XCTAssertEqual(dict["display_name"] as? String, "d06227105@ntu.edu.tw")
        XCTAssertEqual(dict["enabled"] as? Bool, true)
    }
}
