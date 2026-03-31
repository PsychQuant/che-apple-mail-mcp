import XCTest
@testable import MailSQLite

final class BatchEmptyTests: XCTestCase {

    // MARK: - Empty Batch

    func testEmptyBatchReturnsEmptyResults() {
        var results: [[String: Any]] = []
        let emptyBatch: [[String: String]] = []
        for email in emptyBatch {
            // Simulate the batch loop pattern from Server.swift:
            // each item would be processed and appended to results.
            let entry: [String: Any] = ["id": email["id"] ?? ""]
            results.append(entry)
        }
        XCTAssertTrue(results.isEmpty, "An empty batch input should produce an empty results array")
    }

    // MARK: - Batch Validator Accepts Zero

    func testBatchValidatorAcceptsZeroSize() {
        XCTAssertNoThrow(
            try BatchValidator.validateBatchSize(0),
            "BatchValidator should not throw for a batch size of 0"
        )
    }

    // MARK: - Single Item Batch

    func testSingleItemBatch() {
        var results: [[String: Any]] = []
        let singleItemBatch: [[String: String]] = [
            ["id": "999999999", "mailbox_url": "imap://fake/INBOX"]
        ]
        for email in singleItemBatch {
            let rowId = Int(email["id"] ?? "") ?? 0
            let mailboxURL = email["mailbox_url"] ?? ""
            do {
                _ = try EmlxParser.readEmail(rowId: rowId, mailboxURL: mailboxURL)
                results.append(["id": email["id"] ?? "", "status": "ok"])
            } catch {
                // Error is expected for a fake mailbox — record it and continue.
                results.append(["id": email["id"] ?? "", "error": "\(error)"])
            }
        }
        XCTAssertEqual(results.count, 1, "Single-item batch should produce exactly 1 result")
        // The fake mailbox will fail, so verify the error was caught gracefully.
        XCTAssertNotNil(results.first?["error"], "Expected an error entry for the fake mailbox")
    }
}
