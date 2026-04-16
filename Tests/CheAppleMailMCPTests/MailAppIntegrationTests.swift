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

    // MARK: - Helpers

    private func uniqueSubject(_ mode: String) -> String {
        return "\(Self.testDraftSubjectPrefix)\(mode)-\(UUID().uuidString.prefix(8))"
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
                            if s contains "\(Self.testDraftSubjectPrefix)" then
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
