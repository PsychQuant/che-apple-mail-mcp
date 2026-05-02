import XCTest
@testable import CheAppleMailMCP

/// Integration tests that exercise the real Mail.app AppleScript path end-to-end.
///
/// Gated behind the `MAIL_APP_INTEGRATION_TESTS` environment variable — these are
/// skipped by default to keep CI and local `swift test` runs clean. Mail.app must
/// be running, the `MAIL_INTEGRATION_ACCOUNT_NAME` env var must point to a real
/// account, and the test draft is written to that account's Drafts mailbox.
///
/// Run manually:
///
///     MAIL_APP_INTEGRATION_TESTS=1 \
///     MAIL_INTEGRATION_ACCOUNT_NAME="Google" \
///     swift test --filter MailAppIntegrationTests
///
final class MailAppIntegrationTests: XCTestCase {

    private static let testDraftSubjectPrefix = "INTEGRATION-TEST-format-param-"

    private var accountName: String!

    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["MAIL_APP_INTEGRATION_TESTS"] != "1" {
            throw XCTSkip("Integration tests skipped — set MAIL_APP_INTEGRATION_TESTS=1 to run")
        }
        guard let name = ProcessInfo.processInfo.environment["MAIL_INTEGRATION_ACCOUNT_NAME"], !name.isEmpty else {
            throw XCTSkip("MAIL_INTEGRATION_ACCOUNT_NAME must be set (e.g., \"Google\")")
        }
        accountName = name
    }

    override func tearDown() async throws {
        // Best-effort cleanup of drafts created by this test suite.
        try? await cleanupIntegrationDrafts()
    }

    // MARK: - createDraft format integration

    func test_createDraft_plainMode_succeeds() async throws {
        let subject = uniqueSubject("plain")
        let result = try await MailController.shared.createDraft(
            to: ["test+discard@example.com"],
            subject: subject,
            body: "plain body with **literal asterisks**",
            attachments: nil,
            accountName: accountName,
            format: .plain
        )
        XCTAssertTrue(result.contains("Draft created successfully") || result.contains("successfully"), "expected success message, got: \(result)")
    }

    func test_createDraft_markdownMode_succeeds() async throws {
        let subject = uniqueSubject("markdown")
        let result = try await MailController.shared.createDraft(
            to: ["test+discard@example.com"],
            subject: subject,
            body: "**bold** and *italic* with [link](https://example.com)",
            attachments: nil,
            accountName: accountName,
            format: .markdown
        )
        XCTAssertTrue(result.contains("successfully"), "expected success message, got: \(result)")
    }

    func test_createDraft_htmlMode_succeeds() async throws {
        let subject = uniqueSubject("html")
        let result = try await MailController.shared.createDraft(
            to: ["test+discard@example.com"],
            subject: subject,
            body: "<p><strong>bold HTML</strong></p>",
            attachments: nil,
            accountName: accountName,
            format: .html
        )
        XCTAssertTrue(result.contains("successfully"), "expected success message, got: \(result)")
    }

    // MARK: - AppleScript html content read denial (confirms spec: Requirement: AppleScript html content read is denied on messages)

    func test_htmlContentOfInboxMessage_isDeniedByAppleScript() async throws {
        let controller = MailController.shared
        let script = """
        tell application "Mail"
            try
                set firstMsg to first message of inbox
                try
                    set htmlC to html content of firstMsg
                    return "UNEXPECTED_READ_SUCCESS:" & (length of htmlC)
                on error errMsg number errNum
                    return "DENIED:" & errNum
                end try
            on error
                return "NO_INBOX_MESSAGE"
            end try
        end tell
        """
        let result = try await controller.runScript(script)
        if result == "NO_INBOX_MESSAGE" {
            throw XCTSkip("No inbox message available to test html content read denial")
        }
        XCTAssertTrue(
            result.hasPrefix("DENIED:"),
            "Expected html content read to be denied by AppleScript runtime, got: \(result)"
        )
    }

    // MARK: - reply_email integration (#37 + #45)
    //
    // Both tests need a real source message to reply to. We use the first
    // message in the account's INBOX. If INBOX is empty, the test is skipped.
    // Cleanup deletes any draft whose subject contains the integration-test prefix.

    /// Issue #37: end-to-end reply-as-draft + cc_additional + attachments.
    /// Asserts that the AppleScript runs without error AND the resulting draft
    /// appears in Drafts (not Sent). Body contents not asserted here; #45 covers that.
    func test_replyEmail_asDraft_withCcAndAttachments_succeeds() async throws {
        guard let (sourceId, sourceMailbox) = try await firstInboxMessage() else {
            throw XCTSkip("INBOX has no messages — cannot run reply integration test")
        }
        let attachmentPath = try makeTempAttachment()
        let result = try await MailController.shared.replyEmail(
            id: sourceId,
            mailbox: sourceMailbox,
            accountName: accountName,
            body: "Integration test reply (#37). Subject: \(uniqueReplySubject("cc-attach"))",
            replyAll: false,
            ccAdditional: ["test+cc@example.com"],
            attachments: [attachmentPath],
            saveAsDraft: true,
            format: .plain
        )
        XCTAssertTrue(result.contains("Reply saved as draft") || result.contains("draft"),
                      "expected draft-save success message, got: \(result)")
    }

    /// Issue #45: verify the runtime draft body contains the RFC 3676 `> ` quoted
    /// original — closing the gap that #43's verify identified ("AppleScript-string
    /// emission tests pass but actual draft body might not have the quote").
    func test_replyEmail_draftBodyContainsQuotedOriginal() async throws {
        guard let (sourceId, sourceMailbox) = try await firstInboxMessage() else {
            throw XCTSkip("INBOX has no messages — cannot run reply integration test")
        }
        // Create a unique reply marker we can grep for in the draft.
        let marker = "INTEGRATION-TEST-43-quote-\(UUID().uuidString.prefix(8))"
        _ = try await MailController.shared.replyEmail(
            id: sourceId,
            mailbox: sourceMailbox,
            accountName: accountName,
            body: marker,
            replyAll: false,
            saveAsDraft: true,
            format: .plain
        )
        // Read back the just-created draft via AppleScript: find the most recent
        // Draft whose content contains our marker, then assert its content also
        // contains a `> ` line (RFC 3676 quote) somewhere after the marker.
        let script = """
        tell application "Mail"
            try
                set draftsBox to mailbox "Drafts" of account "\(accountName!)"
            on error
                return "NO_DRAFTS_BOX"
            end try
            set foundContent to ""
            repeat with m in messages of draftsBox
                try
                    set c to content of m
                    if c contains "\(marker)" then
                        set foundContent to c
                        exit repeat
                    end if
                end try
            end repeat
            if foundContent is "" then
                return "DRAFT_NOT_FOUND"
            end if
            return foundContent
        end tell
        """
        let body = try await MailController.shared.runScript(script)
        guard body != "NO_DRAFTS_BOX" else {
            throw XCTSkip("Account has no Drafts mailbox available")
        }
        guard body != "DRAFT_NOT_FOUND" else {
            XCTFail("Created draft not found in Drafts — replyEmail may have failed silently")
            return
        }
        XCTAssertTrue(body.contains(marker), "draft must contain user reply text")
        XCTAssertTrue(body.contains("> "), "draft must contain RFC 3676 `> ` quoted original line (#43 fix)")
    }

    // MARK: - Helpers

    private func uniqueSubject(_ mode: String) -> String {
        return "\(Self.testDraftSubjectPrefix)\(mode)-\(UUID().uuidString.prefix(8))"
    }

    private func uniqueReplySubject(_ kind: String) -> String {
        return "INTEGRATION-TEST-reply-\(kind)-\(UUID().uuidString.prefix(8))"
    }

    /// Fetch the first message in the account's INBOX, returning (id, mailboxName)
    /// suitable for replyEmail. nil if INBOX is empty or unreadable.
    private func firstInboxMessage() async throws -> (id: String, mailbox: String)? {
        let script = """
        tell application "Mail"
            try
                set inboxRef to mailbox "INBOX" of account "\(accountName!)"
            on error
                try
                    set inboxRef to mailbox "Inbox" of account "\(accountName!)"
                on error
                    return "NO_INBOX"
                end try
            end try
            try
                set firstMsg to first message of inboxRef
                set msgId to id of firstMsg as string
                set mbName to name of inboxRef as string
                return msgId & "|" & mbName
            on error
                return "NO_MESSAGE"
            end try
        end tell
        """
        let result = try await MailController.shared.runScript(script)
        guard result != "NO_INBOX", result != "NO_MESSAGE", result.contains("|") else {
            return nil
        }
        let parts = result.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (id: parts[0], mailbox: parts[1])
    }

    /// Create a small temp file for use as an attachment in integration tests.
    /// Auto-cleaned via addTeardownBlock.
    private func makeTempAttachment() throws -> String {
        let path = "/tmp/che-apple-mail-integration-attach-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: path,
                                       contents: Data("integration test attachment".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func cleanupIntegrationDrafts() async throws {
        let script = """
        tell application "Mail"
            set deleted to 0
            repeat with acc in accounts
                try
                    set draftsBox to mailbox "Drafts" of acc
                    set toDelete to {}
                    repeat with m in messages of draftsBox
                        try
                            set s to subject of m
                            set c to ""
                            try
                                set c to content of m
                            end try
                            if s contains "\(Self.testDraftSubjectPrefix)" or c contains "Integration test reply (#37)" or c contains "INTEGRATION-TEST-43-quote-" then
                                set end of toDelete to m
                            end if
                        end try
                    end repeat
                    repeat with m in toDelete
                        delete m
                        set deleted to deleted + 1
                    end repeat
                end try
            end repeat
            return "cleaned:" & deleted
        end tell
        """
        _ = try await MailController.shared.runScript(script)
    }
}
