import XCTest
@testable import MailSQLite

final class AccountMapperTests: XCTestCase {

    // MARK: - buildMapping

    func testBuildMappingFromRealPlist() {
        let mapping = AccountMapper.buildMapping()
        // The plist may not exist on CI or fresh machines — skip if empty.
        guard !mapping.isEmpty else {
            // Not a failure; plist simply not available.
            return
        }
        // Filter to entries where extractEmail succeeded (contains @).
        // Entries without @ are EWS/opaque URLs stored as fallbacks.
        let emailEntries = mapping.filter { $0.value.contains("@") }
        XCTAssertFalse(emailEntries.isEmpty, "At least one mapping value should be an email address")
        for (_, email) in emailEntries {
            XCTAssertTrue(
                email.contains("@"),
                "Email entry should contain '@', got: \(email)"
            )
        }
    }

    func testBuildMappingWithNonexistentPath() {
        let mapping = AccountMapper.buildMapping(path: "/nonexistent/path")
        XCTAssertTrue(mapping.isEmpty, "Non-existent path should return empty dictionary")
    }

    // MARK: - extractEmail

    func testExtractEmailFromImapURL() {
        let email = AccountMapper.extractEmail(from: "imap://kiki830621%40gmail.com/")
        XCTAssertEqual(email, "kiki830621@gmail.com")
    }

    func testExtractEmailFromEwsURL() {
        let email = AccountMapper.extractEmail(from: "ews://AAMkAGE5==/")
        XCTAssertNil(email, "EWS URLs with opaque identifiers should return nil")
    }

    func testExtractEmailPercentDecoding() {
        let email = AccountMapper.extractEmail(from: "imap://user%40example.com/")
        XCTAssertEqual(email, "user@example.com")
    }

    // MARK: - EWS fallback (#9)

    /// Regression test for #9: when the AccountURL is an opaque EWS URL
    /// (no `@`), `buildMapping` must not leak the raw
    /// `ews://AAMkA...==/` string back out as a "display name" — it
    /// was showing up verbatim in search_emails results and users
    /// couldn't tell one Exchange account from another.
    func testBuildMappingKeepsEwsAccountsUsableAsDisplayNames() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "accountmap-fixture-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let uuid = "ABCE3A85-06BE-43BC-9B84-2CA6F325612F"
        let opaqueEwsURL = "ews://AAMkAGE5MTZiZmU5LTAwOTMtNDM5NS1iMDY0LTJiMzRiMDMyYmVkNQAuAAAAAADY4uxeaw46TY4LdJuSkRHwAQDNnfYurfD3RqrCoW9cE+eeAAAAMbxOAAA=/"
        let plist: [String: Any] = [
            uuid: ["AccountURL": opaqueEwsURL]
        ]
        let plistPath = tmpDir.appendingPathComponent("AccountsMap.plist").path
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: URL(fileURLWithPath: plistPath))

        let mapping = AccountMapper.buildMapping(path: plistPath)
        let value = try XCTUnwrap(mapping[uuid], "EWS entry should still be mapped")

        XCTAssertNotEqual(
            value, opaqueEwsURL,
            "buildMapping must not store the raw EWS AccountURL as the display name"
        )
        XCTAssertFalse(
            value.hasPrefix("ews://"),
            "Mapped value should not start with ews:// — got \(value)"
        )
        XCTAssertFalse(
            value.contains("=="),
            "Mapped value should not contain base64 padding — got \(value)"
        )
    }

    /// Reverse-lookup consistency (#9): callers look up accounts by doing
    /// `accountMap.first(where: { $0.value == accountName })?.key`. For the
    /// EWS fallback (value == UUID == key) that lookup must still resolve
    /// back to the correct UUID.
    func testEwsAccountRoundTripsThroughReverseLookup() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "accountmap-roundtrip-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let ewsUUID = "ABCE3A85-06BE-43BC-9B84-2CA6F325612F"
        let imapUUID = "C38E0583-47F8-4468-BE70-43155C15549D"
        let plist: [String: Any] = [
            ewsUUID: ["AccountURL": "ews://AAMkAGE5==/"],
            imapUUID: ["AccountURL": "imap://user%40example.com/"]
        ]
        let plistPath = tmpDir.appendingPathComponent("AccountsMap.plist").path
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: URL(fileURLWithPath: plistPath))

        let mapping = AccountMapper.buildMapping(path: plistPath)

        // IMAP: display name → UUID by reverse lookup
        let imapKey = mapping.first(where: { $0.value == "user@example.com" })?.key
        XCTAssertEqual(imapKey, imapUUID)

        // EWS: the only handle the user has is the UUID itself; reverse
        // lookup on that UUID must find exactly the same UUID key.
        let ewsKey = mapping.first(where: { $0.value == ewsUUID })?.key
        XCTAssertEqual(ewsKey, ewsUUID, "EWS UUID must round-trip through reverse lookup")

        // Make sure the two accounts don't collide on each other's values.
        XCTAssertNotEqual(
            mapping.first(where: { $0.value == ewsUUID })?.key,
            imapUUID
        )
    }
}
