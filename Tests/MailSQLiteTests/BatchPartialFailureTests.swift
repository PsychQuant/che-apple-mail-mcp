import XCTest
@testable import MailSQLite

final class BatchPartialFailureTests: XCTestCase {

    // MARK: - Test 1: Invalid ID throws emlxNotFound

    func testReadEmailWithInvalidIdThrows() {
        XCTAssertThrowsError(
            try EmlxParser.readEmail(rowId: 999999999, mailboxURL: "imap://fake/INBOX")
        ) { error in
            guard let mailError = error as? MailSQLiteError else {
                XCTFail("Expected MailSQLiteError, got \(type(of: error)): \(error)")
                return
            }
            if case .emlxNotFound(let messageId, _) = mailError {
                XCTAssertEqual(messageId, 999999999)
            } else {
                XCTFail("Expected .emlxNotFound, got \(mailError)")
            }
        }
    }

    // MARK: - Test 2: Batch partial failure pattern

    func testBatchPartialFailurePattern() throws {
        let dbPath = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Envelope Index not available")
        }

        let reader = try EnvelopeIndexReader(databasePath: dbPath)
        let results = try reader.search(SearchParameters(query: "a", limit: 20))

        // Find 2 valid message IDs that can actually be read
        var validItems: [(rowId: Int, mailboxURL: String)] = []
        for result in results {
            guard let mailboxUrl = try reader.mailboxURL(forMessageId: result.id) else { continue }
            do {
                _ = try EmlxParser.readEmail(rowId: result.id, mailboxURL: mailboxUrl)
                validItems.append((rowId: result.id, mailboxURL: mailboxUrl))
                if validItems.count == 2 { break }
            } catch {
                continue
            }
        }

        guard validItems.count == 2 else {
            throw XCTSkip("Could not find 2 readable emails to compose a batch")
        }

        // Build a batch of 3: 2 valid + 1 invalid
        let batchItems: [(rowId: Int, mailboxURL: String)] = [
            validItems[0],
            (rowId: 999999999, mailboxURL: "imap://fake/INBOX"),
            validItems[1],
        ]

        // Simulate batch: collect per-item results, catching errors individually
        enum BatchResult {
            case success(EmailContent)
            case failure(Error)
        }

        var batchResults: [BatchResult] = []
        for item in batchItems {
            do {
                let content = try EmlxParser.readEmail(
                    rowId: item.rowId,
                    mailboxURL: item.mailboxURL
                )
                batchResults.append(.success(content))
            } catch {
                batchResults.append(.failure(error))
            }
        }

        XCTAssertEqual(batchResults.count, 3, "Should have 3 results total")

        let successCount = batchResults.filter {
            if case .success = $0 { return true }
            return false
        }.count

        let failureCount = batchResults.filter {
            if case .failure = $0 { return true }
            return false
        }.count

        XCTAssertEqual(successCount, 2, "Should have 2 successful reads")
        XCTAssertEqual(failureCount, 1, "Should have 1 failed read")

        // The failure should be the second item (index 1)
        if case .failure(let error) = batchResults[1] {
            XCTAssertTrue(error is MailSQLiteError, "Error should be MailSQLiteError")
        } else {
            XCTFail("Expected failure at index 1 (the invalid ID)")
        }
    }

    // MARK: - Test 3: Failed entry contains error info with message ID

    func testFailedEntryContainsErrorInfo() {
        let invalidRowId = 999999999
        do {
            _ = try EmlxParser.readEmail(rowId: invalidRowId, mailboxURL: "imap://fake/INBOX")
            XCTFail("Expected readEmail to throw for invalid row ID")
        } catch let error as MailSQLiteError {
            if case .emlxNotFound(let messageId, let path) = error {
                XCTAssertEqual(messageId, invalidRowId,
                    "Error should contain the requested message ID")
                XCTAssertTrue(path.contains("\(invalidRowId)"),
                    "Error path should reference the message ID, got: \(path)")
            } else {
                XCTFail("Expected .emlxNotFound, got \(error)")
            }

            // Verify the localized description also contains the ID
            let description = error.errorDescription ?? ""
            XCTAssertTrue(description.contains("\(invalidRowId)"),
                "Error description should contain the message ID, got: \(description)")
        } catch {
            XCTFail("Expected MailSQLiteError, got \(type(of: error)): \(error)")
        }
    }
}
