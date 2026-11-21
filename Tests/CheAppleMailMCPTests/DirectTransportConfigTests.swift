import XCTest
@testable import CheAppleMailMCP

/// #742 — Requirement: Direct transport is available only for accounts configured for it.
final class DirectTransportConfigTests: XCTestCase {

    private func file(_ text: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dt-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("direct-transport.json")
        if let text { try Data(text.utf8).write(to: url) }
        return url
    }

    private let valid = """
    {"accounts": [{"account_id": "UUID-I", "address": "me@icloud.example",
      "smtp": {"host": "smtp.mail.me.com", "port": 587}, "imap": {"host": "imap.mail.me.com", "port": 993},
      "sent_copy": "append", "allowed_from": ["alias@icloud.example"]}]}
    """

    func testAMissingFileIsNoConfiguration() throws {
        XCTAssertNil(try DirectTransportConfig.load(from: try file(nil)))
    }

    func testAValidFileIsRead() throws {
        let config = try XCTUnwrap(try DirectTransportConfig.load(from: try file(valid)))
        let account = try XCTUnwrap(config.account(accountID: "UUID-I", accountName: nil))
        XCTAssertEqual(account.address, "me@icloud.example")
        XCTAssertEqual(account.smtp, .init(host: "smtp.mail.me.com", port: 587))
        XCTAssertEqual(account.imap, .init(host: "imap.mail.me.com", port: 993))
        XCTAssertEqual(account.sentCopy, .append)
        XCTAssertEqual(account.allowedFrom, ["alias@icloud.example"])
    }

    func testAnAccountIsFoundByItsIdOrItsAddress_andNotOtherwise() throws {
        let config = try XCTUnwrap(try DirectTransportConfig.load(from: try file(valid)))
        XCTAssertNotNil(config.account(accountID: "uuid-i", accountName: nil), "ASCII case of the id is ignored")
        XCTAssertNotNil(config.account(accountID: nil, accountName: "ME@icloud.example"))
        XCTAssertNil(config.account(accountID: "UUID-Z", accountName: "me@icloud.example"),
                     "an id that is given chooses the account; the name is not consulted")
        XCTAssertNil(config.account(accountID: nil, accountName: "iCloud"))
        XCTAssertNil(config.account(accountID: nil, accountName: nil))
    }

    /// A file that exists and cannot be used is refused, never read as "not configured".
    func testAFileThatCannotBeUsedIsRefusedNamingTheProblem() throws {
        let cases: [(String, String)] = [
            ("not json", "not valid JSON"),
            ("[]", "an object"),
            (#"{"accounts": {}}"#, "accounts"),
            (valid.replacingOccurrences(of: #""append""#, with: #""maybe""#), "sent_copy"),
            (valid.replacingOccurrences(of: #""port": 587"#, with: #""port": 0"#), "port"),
            (valid.replacingOccurrences(of: #""port": 587"#, with: #""port": "587""#), "port"),
            (valid.replacingOccurrences(of: #""address": "me@icloud.example","#, with: ""), "address"),
            (valid.replacingOccurrences(of: #""address": "me@icloud.example""#, with: #""address": "me""#), "address"),
            (valid.replacingOccurrences(of: #""sent_copy""#, with: #""password": "x", "sent_copy""#), "password"),
            (valid.replacingOccurrences(of: #"{"accounts""#, with: #"{"extra": 1, "accounts""#), "extra"),
            (valid.replacingOccurrences(of: #"["alias@icloud.example"]"#, with: #"[5]"#), "allowed_from"),
            (valid.replacingOccurrences(of: #""smtp.mail.me.com""#, with: #""""#), "host"),
        ]
        for (text, word) in cases {
            XCTAssertThrowsError(try DirectTransportConfig.load(from: try file(text)), word) { error in
                let message = "\(error)"
                XCTAssertTrue(message.contains("direct-transport.json"), message)
                XCTAssertTrue(message.contains(word), "\(word): \(message)")
            }
        }
    }

    func testTwoEntriesForOneAccountAreRefused() throws {
        let one = #"{"account_id": "UUID-I", "address": "me@icloud.example", "smtp": {"host": "s", "port": 587}, "imap": {"host": "i", "port": 993}, "sent_copy": "provider", "allowed_from": []}"#
        XCTAssertThrowsError(try DirectTransportConfig.load(from: try file(#"{"accounts": [\#(one), \#(one)]}"#))) { error in
            XCTAssertTrue("\(error)".contains("UUID-I"), "\(error)")
        }
    }
}
