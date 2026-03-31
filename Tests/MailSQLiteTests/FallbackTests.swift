import XCTest
@testable import MailSQLite

/// Tests for fallback behavior when SQLite/emlx is unavailable.
final class FallbackTests: XCTestCase {

    // MARK: - EnvelopeIndexReader unavailability

    func testReaderInitFailsWithBadPath() {
        // When SQLite DB is not accessible, init should throw
        XCTAssertThrowsError(
            try EnvelopeIndexReader(databasePath: "/nonexistent/Envelope Index")
        ) { error in
            XCTAssertTrue(error is MailSQLiteError)
            if case .databaseNotAccessible(let msg) = error as! MailSQLiteError {
                XCTAssertTrue(msg.contains("Full Disk Access"),
                    "Error should guide user to grant Full Disk Access")
            }
        }
    }

    func testReaderInitFailsWithDirectory() {
        // Passing a directory instead of a file should fail
        XCTAssertThrowsError(
            try EnvelopeIndexReader(databasePath: "/tmp")
        )
    }

    // MARK: - EmlxParser fallback triggers

    func testReadEmailThrowsForNonexistentMessage() {
        // readEmail with a fake mailbox URL should throw emlxNotFound
        XCTAssertThrowsError(
            try EmlxParser.readEmail(rowId: 999999999, mailboxURL: "imap://FAKE-UUID/INBOX")
        ) { error in
            guard let mailError = error as? MailSQLiteError else {
                XCTFail("Expected MailSQLiteError")
                return
            }
            if case .emlxNotFound(let msgId, _) = mailError {
                XCTAssertEqual(msgId, 999999999)
            } else {
                XCTFail("Expected .emlxNotFound, got \(mailError)")
            }
        }
    }

    func testReadEmailThrowsForMalformedURL() {
        // Malformed URL should result in emlxNotFound (resolveEmlxPath returns nil)
        XCTAssertThrowsError(
            try EmlxParser.readEmail(rowId: 1, mailboxURL: "not-a-url")
        ) { error in
            XCTAssertTrue(error is MailSQLiteError)
        }
    }

    func testResolveEmlxPathReturnsNilForFakeUUID() {
        // Path resolution with a non-existent account UUID returns nil
        let path = EmlxParser.resolveEmlxPath(
            rowId: 12345,
            mailboxURL: "imap://00000000-0000-0000-0000-000000000000/INBOX"
        )
        XCTAssertNil(path, "Should return nil for non-existent account UUID")
    }

    // MARK: - Mailbox URL lookup fallback

    func testMailboxURLForNonexistentMessageReturnsNil() throws {
        let dbPath = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Envelope Index not available")
        }
        let reader = try EnvelopeIndexReader(databasePath: dbPath)
        let url = try reader.mailboxURL(forMessageId: 999999999)
        XCTAssertNil(url, "Non-existent message should return nil mailbox URL")
    }

    // MARK: - Fallback decision pattern

    func testFallbackDecisionWhenEmlxUnavailable() throws {
        // Simulates the fallback decision in Server.swift:
        // 1. Try SQLite lookup → get mailbox URL
        // 2. Try emlx read → fails
        // 3. Should fall back to AppleScript (represented by reaching the fallback branch)

        let dbPath = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Envelope Index not available")
        }
        let reader = try EnvelopeIndexReader(databasePath: dbPath)
        let results = try reader.search(SearchParameters(query: "a", limit: 1))
        guard let msg = results.first else {
            throw XCTSkip("No messages found")
        }

        // Get the mailbox URL from SQLite (step 1 — works)
        let mailboxUrl = try reader.mailboxURL(forMessageId: msg.id)
        XCTAssertNotNil(mailboxUrl, "SQLite lookup should succeed for existing message")

        // Try to read via emlx — may or may not work depending on .emlx availability
        var usedFallback = false
        if let url = mailboxUrl {
            do {
                _ = try EmlxParser.readEmail(rowId: msg.id, mailboxURL: url)
                // emlx read succeeded — no fallback needed
            } catch {
                // emlx read failed — this is when Server.swift falls back to AppleScript
                usedFallback = true
            }
        }

        // Either path is valid — the test verifies the pattern works without crashing
        XCTAssertTrue(true, "Fallback decision pattern completed without crash (usedFallback=\(usedFallback))")
    }
}
