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
}
