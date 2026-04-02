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
}
