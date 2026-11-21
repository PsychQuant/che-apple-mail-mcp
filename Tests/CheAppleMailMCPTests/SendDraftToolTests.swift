import MCP
import XCTest
@testable import CheAppleMailMCP

/// #742 — the `send_draft` tool around the flow: arguments, configuration,
/// credential and result. A stand-in server; no keychain, no network, no Mail.
final class SendDraftToolTests: XCTestCase {

    private let config = """
    {"accounts": [{"account_id": "UUID-I", "address": "me@icloud.example",
      "smtp": {"host": "smtp.example", "port": 587}, "imap": {"host": "imap.example", "port": 993},
      "sent_copy": "append", "allowed_from": []}]}
    """

    private final class Opened: @unchecked Sendable {
        var count = 0
        var password: String?
    }

    private func environment(config text: String?, password: String? = "secret-pw",
                             session: SendDraftFlowTests.FakeSession = SendDraftFlowTests.FakeSession(),
                             opened: Opened = Opened()) throws -> SendDraftTool.Environment {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dt-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        if let text { try Data(text.utf8).write(to: dir.appendingPathComponent(DirectTransportConfig.fileName)) }
        return SendDraftTool.Environment(
            stateDirectory: dir,
            password: { _ in password },
            openSession: { _, pw in opened.count += 1; opened.password = pw; return session },
            localMessageID: { _ in "<d1@icloud.example>" },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private func draft() -> FetchedDraft {
        FetchedDraft(uid: 7, message: Data("From: me@icloud.example\r\nTo: me@icloud.example\r\nSubject: Report\r\n\r\nbody".utf8),
                     messageID: "<d1@icloud.example>", subject: "Report", from: ["me@icloud.example"],
                     recipients: ["me@icloud.example"], hasInvalidRecipient: false)
    }

    private func failure(_ arguments: [String: Value], _ environment: SendDraftTool.Environment) async -> String? {
        do { _ = try await SendDraftTool.run(arguments, environment); return nil } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func testAnArgumentOutsideTheListIsRefusedByName_beforeAnyConnection() async throws {
        let opened = Opened()
        let env = try environment(config: config, opened: opened)
        for extra in ["body", "to", "cc", "bcc", "attachments", "save_as_draft"] {
            let message = await failure(["account_id": .string("UUID-I"), "draft_id": .string("5"), extra: .string("x")], env)
            XCTAssertTrue(message?.contains("'\(extra)'") == true, "\(extra): \(message ?? "not refused")")
        }
        XCTAssertEqual(opened.count, 0)
    }

    func testExactlyOneSelectorIsRequired() async throws {
        let env = try environment(config: config)
        for arguments: [String: Value] in [
            ["account_id": .string("UUID-I")],
            ["account_id": .string("UUID-I"), "draft_id": .string("5"), "subject_match": .string("Report")],
        ] {
            let message = await failure(arguments, env)
            XCTAssertTrue(message?.contains("exactly one of draft_id and subject_match") == true, message ?? "not refused")
        }
        let bad = await failure(["account_id": .string("UUID-I"), "draft_id": .string("abc")], env)
        XCTAssertTrue(bad?.contains("numeric") == true, bad ?? "not refused")
    }

    func testNoConfigurationAndAnUnconfiguredAccountAreRefused_withoutConnecting() async throws {
        let opened = Opened()
        let none = try environment(config: nil, opened: opened)
        let first = await failure(["account_id": .string("UUID-I"), "draft_id": .string("5")], none)
        XCTAssertTrue(first?.contains("not configured") == true, first ?? "not refused")
        let other = try environment(config: config, opened: opened)
        let second = await failure(["account_name": .string("someone@else.example"), "draft_id": .string("5")], other)
        XCTAssertTrue(second?.contains("not configured for someone@else.example") == true, second ?? "not refused")
        XCTAssertEqual(opened.count, 0)
    }

    func testAnUnreadableConfigurationIsRefused_notTreatedAsAbsent() async throws {
        let env = try environment(config: "{ not json")
        let message = await failure(["account_id": .string("UUID-I"), "draft_id": .string("5")], env)
        XCTAssertTrue(message?.contains("direct-transport.json: is not valid JSON") == true, message ?? "not refused")
    }

    func testAMissingCredentialIsRefusedNamingTheCommandLineMode_withoutConnecting() async throws {
        let opened = Opened()
        let env = try environment(config: config, password: nil, opened: opened)
        let message = await failure(["account_id": .string("UUID-I"), "draft_id": .string("5")], env)
        XCTAssertTrue(message?.contains("--direct-transport-set-credential me@icloud.example") == true, message ?? "not refused")
        XCTAssertEqual(opened.count, 0)
    }

    func testASentDraftReturnsTheOutcomeAndStages_andThePasswordAppearsNowhere() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = [draft()]
        let opened = Opened()
        let env = try environment(config: config, session: session, opened: opened)
        let text = try await SendDraftTool.run(["account_id": .string("UUID-I"), "subject_match": .string("Report")], env)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "submitted")
        XCTAssertEqual(object["message_id"] as? String, "<d1@icloud.example>")
        XCTAssertEqual(object["sent_copy"] as? String, "done")
        XCTAssertEqual(object["draft_removal"] as? String, "done")
        XCTAssertEqual(object["resumed"] as? Bool, false)
        XCTAssertEqual(opened.password, "secret-pw", "the stored password reaches the connection")
        XCTAssertFalse(text.contains("secret-pw"), "and nothing else")
        let record = String(decoding: try Data(contentsOf: env.stateDirectory.appendingPathComponent(SendRecordStore.fileName)), as: UTF8.self)
        XCTAssertFalse(record.contains("secret-pw"))
    }

    /// spec-example: direct-transport / The description carries the caveat
    func testTheListedDescriptionSaysItHasNotRunAgainstARealServer_andNamesTheIssue() throws {
        let tool = try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == "send_draft" })
        let text = try XCTUnwrap(tool.description)
        XCTAssertTrue(text.contains("NOT YET RUN AGAINST A REAL MAIL SERVER"), text)
        XCTAssertTrue(text.contains("#742"), text)
        XCTAssertEqual(ToolAccess.of("send_draft"), .send)
    }

    func testARefusalFromTheFlowIsReportedAsTheToolError() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = []
        let env = try environment(config: config, session: session)
        let message = await failure(["account_id": .string("UUID-I"), "subject_match": .string("Report")], env)
        XCTAssertTrue(message?.contains("no draft in the server's drafts mailbox matched") == true, message ?? "not refused")
    }
}
