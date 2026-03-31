import XCTest
@testable import MailSQLite

final class EmlxFormatTests: XCTestCase {

    // MARK: - Well-Formed Data

    func testExtractMessageDataFromValidEmlx() throws {
        let message = "From: test@example.com\r\nSubject: Hello\r\n\r\nBody text"
        let messageData = Data(message.utf8)
        let emlx = makeEmlx(messageData: messageData)

        let result = try EmlxFormat.extractMessageData(from: emlx)
        XCTAssertEqual(result, messageData)
    }

    func testExtractMessageDataPreservesExactBytes() throws {
        // Verify byte-for-byte preservation including CRLF and binary-safe boundaries
        var messageData = Data([0x46, 0x72, 0x6F, 0x6D, 0x3A, 0x20]) // "From: "
        messageData.append(contentsOf: [0x00, 0xFF, 0x0D, 0x0A]) // null + 0xFF + CRLF
        let emlx = makeEmlx(messageData: messageData)

        let result = try EmlxFormat.extractMessageData(from: emlx)
        XCTAssertEqual(result, messageData)
    }

    func testExtractEmptyMessage() throws {
        let messageData = Data()
        let emlx = makeEmlx(messageData: messageData)

        let result = try EmlxFormat.extractMessageData(from: emlx)
        XCTAssertEqual(result, messageData)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Trailing Plist Data Is Ignored

    func testTrailingPlistDataIsIgnored() throws {
        let message = "Subject: Test\r\n\r\nHello"
        let messageData = Data(message.utf8)

        // Build emlx with trailing Apple plist metadata
        let plist = """

            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
              "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>date-received</key>
                <integer>1700000000</integer>
                <key>flags</key>
                <integer>8590195713</integer>
            </dict>
            </plist>
            """

        var emlx = makeEmlx(messageData: messageData)
        emlx.append(Data(plist.utf8))

        let result = try EmlxFormat.extractMessageData(from: emlx)
        XCTAssertEqual(result, messageData,
                       "Trailing plist metadata should not affect extracted message data")
    }

    func testTrailingGarbageIsIgnored() throws {
        let message = "Hello"
        let messageData = Data(message.utf8)

        var emlx = makeEmlx(messageData: messageData)
        emlx.append(Data(repeating: 0xAB, count: 1024))

        let result = try EmlxFormat.extractMessageData(from: emlx)
        XCTAssertEqual(result, messageData)
    }

    // MARK: - Invalid Byte Count

    func testInvalidByteCountThrows() {
        let invalid = Data("notanumber\nsome data here".utf8)

        XCTAssertThrowsError(try EmlxFormat.extractMessageData(from: invalid)) { error in
            guard let mailError = error as? MailSQLiteError else {
                XCTFail("Expected MailSQLiteError, got \(error)")
                return
            }
            if case .emlxParseFailed(let msg) = mailError {
                XCTAssertTrue(msg.contains("Invalid byte count"),
                              "Error should mention invalid byte count: \(msg)")
            } else {
                XCTFail("Expected .emlxParseFailed, got \(mailError)")
            }
        }
    }

    func testNegativeByteCountThrows() {
        let invalid = Data("-5\nsome data".utf8)

        XCTAssertThrowsError(try EmlxFormat.extractMessageData(from: invalid)) { error in
            guard let mailError = error as? MailSQLiteError,
                  case .emlxParseFailed = mailError else {
                XCTFail("Expected MailSQLiteError.emlxParseFailed, got \(error)")
                return
            }
        }
    }

    func testNoNewlineThrows() {
        let invalid = Data("12345".utf8)

        XCTAssertThrowsError(try EmlxFormat.extractMessageData(from: invalid)) { error in
            guard let mailError = error as? MailSQLiteError else {
                XCTFail("Expected MailSQLiteError, got \(error)")
                return
            }
            if case .emlxParseFailed(let msg) = mailError {
                XCTAssertTrue(msg.contains("No newline"),
                              "Error should mention missing newline: \(msg)")
            } else {
                XCTFail("Expected .emlxParseFailed, got \(mailError)")
            }
        }
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try EmlxFormat.extractMessageData(from: Data())) { error in
            guard let mailError = error as? MailSQLiteError,
                  case .emlxParseFailed = mailError else {
                XCTFail("Expected MailSQLiteError.emlxParseFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Insufficient Data

    func testInsufficientDataThrows() {
        // Header says 100 bytes, but only 5 are available
        let insufficient = Data("100\nHello".utf8)

        XCTAssertThrowsError(try EmlxFormat.extractMessageData(from: insufficient)) { error in
            guard let mailError = error as? MailSQLiteError else {
                XCTFail("Expected MailSQLiteError, got \(error)")
                return
            }
            if case .emlxParseFailed(let msg) = mailError {
                XCTAssertTrue(msg.contains("Insufficient data"),
                              "Error should mention insufficient data: \(msg)")
            } else {
                XCTFail("Expected .emlxParseFailed, got \(mailError)")
            }
        }
    }

    func testByteCountExactlyOneMoreThanAvailableThrows() {
        let message = "Short"
        let messageData = Data(message.utf8)
        // Claim one more byte than actually exists
        let header = Data("\(messageData.count + 1)\n".utf8)
        let emlx = header + messageData

        XCTAssertThrowsError(try EmlxFormat.extractMessageData(from: emlx)) { error in
            guard let mailError = error as? MailSQLiteError,
                  case .emlxParseFailed = mailError else {
                XCTFail("Expected MailSQLiteError.emlxParseFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Real .emlx File (Integration)

    func testParseRealEmlxFileIfAvailable() throws {
        let basePath = EnvelopeIndexReader.mailStoragePath
        let fm = FileManager.default

        guard fm.fileExists(atPath: basePath) else {
            throw XCTSkip("Mail storage not available at \(basePath)")
        }

        // Recursively search for any .emlx file
        guard let emlxPath = findFirstEmlxFile(under: basePath) else {
            throw XCTSkip("No .emlx files found under \(basePath)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: emlxPath))
        let messageData = try EmlxFormat.extractMessageData(from: data)

        // The extracted data should be non-empty and look like RFC 822 text
        XCTAssertFalse(messageData.isEmpty,
                       "Extracted message data from \(emlxPath) should not be empty")

        // Sanity check: RFC 822 messages typically contain a colon (header separator)
        let messageString = String(data: messageData, encoding: .utf8)
            ?? String(data: messageData, encoding: .ascii)
        XCTAssertNotNil(messageString,
                        "Message data should be decodable as text")
        XCTAssertTrue(messageString?.contains(":") ?? false,
                      "RFC 822 message should contain at least one header with a colon")
    }

    // MARK: - Helpers

    /// Build a valid .emlx container from raw message data.
    private func makeEmlx(messageData: Data) -> Data {
        let header = Data("\(messageData.count)\n".utf8)
        return header + messageData
    }

    /// Recursively find the first .emlx file under a directory.
    /// Returns nil if none found. Limits depth to avoid excessive traversal.
    private func findFirstEmlxFile(under path: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var checked = 0
        let maxChecked = 50_000 // safety limit

        while let url = enumerator.nextObject() as? URL {
            checked += 1
            if checked > maxChecked { break }
            if url.pathExtension == "emlx" {
                return url.path
            }
        }
        return nil
    }
}
