import MCP
import XCTest
@testable import CheAppleMailMCP

/// #742 — the `send_draft` tool around the flow: arguments, configuration,
/// credential and result. A stand-in server; no keychain, no network, no Mail.
final class SendDraftToolTests: XCTestCase {

    private let config = """
    {"accounts": [{"account_id": "AAAAAAAA-2222-4333-8444-555555555555", "address": "me@icloud.example",
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
            let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "draft_id": .string("5"), extra: .string("x")], env)
            XCTAssertTrue(message?.contains("'\(extra)'") == true, "\(extra): \(message ?? "not refused")")
        }
        XCTAssertEqual(opened.count, 0)
    }

    // MARK: - #744, choosing the draft by its Message-ID

    func testAMessageIDSelectsTheDraft_withoutReadingTheLocalStore() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = [draft()]
        var base = try environment(config: config, session: session)
        base = SendDraftTool.Environment(stateDirectory: base.stateDirectory, password: base.password,
                                         openSession: base.openSession,
                                         localMessageID: { _ in XCTFail("the local store was read"); return nil },
                                         now: base.now)
        for form in ["<d1@icloud.example>", "d1@icloud.example"] {
            session.drafts = [draft()]
            let text = try await SendDraftTool.run(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                                    "message_id": .string(form)], base)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(object["message_id"] as? String, "<d1@icloud.example>", form)
            try SendRecordStore(directory: base.stateDirectory).remove("<d1@icloud.example>")
        }
    }

    func testAMessageIDWhoseDraftChangesBetweenSearchAndFetchIsRefused() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = [draft()]
        session.fetchOverride = FetchedDraft(uid: 7, message: Data("From: me@icloud.example\r\nTo: me@icloud.example\r\nSubject: Report\r\n\r\nother".utf8),
                                             messageID: "<other@icloud.example>", subject: "Report", from: ["me@icloud.example"],
                                             recipients: ["me@icloud.example"], hasInvalidRecipient: false)
        let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                     "message_id": .string("<d1@icloud.example>")], try environment(config: config, session: session))
        XCTAssertTrue(message?.contains("not the one the search found") == true, message ?? "not refused")
        XCTAssertTrue(session.submitted.isEmpty)
    }

    func testAMessageIDThatAServerHitOnlyContainsSelectsNothing() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.nearMissHits = [DraftSummary(uid: 9, subject: "Report", messageID: "<d1@icloud.example.other>")]
        let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                     "message_id": .string("<d1@icloud.example>")], try environment(config: config, session: session))
        XCTAssertTrue(message?.contains("no draft") == true, message ?? "a substring hit was selected")
        XCTAssertTrue(session.submitted.isEmpty)
    }

    func testAMessageIDThatMatchesNoDraftIsRefused() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = [draft()]
        let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                     "message_id": .string("<other@icloud.example>")], try environment(config: config, session: session))
        XCTAssertTrue(message?.contains("no draft") == true, message ?? "not refused")
    }

    func testAMessageIDBesideAnotherSelector_orMalformed_isRefusedBeforeAnyConnection() async throws {
        let opened = Opened()
        let env = try environment(config: config, opened: opened)
        let both = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                  "message_id": .string("<d1@icloud.example>"), "subject_match": .string("Report")], env)
        XCTAssertTrue(both?.contains("exactly one of") == true, both ?? "not refused")
        for bad in ["no-at-sign", "<a b@icloud.example>", "<d1@icloud.example>\r\nX: y", "", "<" + String(repeating: "a", count: 990) + "@icloud.example>"] {
            let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "message_id": .string(bad)], env)
            XCTAssertTrue(message?.contains("message_id must be") == true, "\(bad.debugDescription): \(message ?? "not refused")")
        }
        let nulled = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "message_id": .null,
                                    "subject_match": .string("Report")], env)
        XCTAssertTrue(nulled?.contains("'message_id' must be a string") == true, nulled ?? "a null selector was accepted")
        XCTAssertEqual(opened.count, 0)
    }

    func testExactlyOneSelectorIsRequired() async throws {
        let env = try environment(config: config)
        for arguments: [String: Value] in [
            ["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555")],
            ["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "draft_id": .string("5"), "subject_match": .string("Report")],
        ] {
            let message = await failure(arguments, env)
            XCTAssertTrue(message?.contains("exactly one of draft_id, subject_match and message_id") == true, message ?? "not refused")
        }
        let nulled = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                    "draft_id": .null, "subject_match": .string("Report")], env)
        XCTAssertTrue(nulled?.contains("'draft_id' must be a string") == true, nulled ?? "a null selector was accepted")
        let bad = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "draft_id": .string("abc")], env)
        XCTAssertTrue(bad?.contains("numeric") == true, bad ?? "not refused")
    }

    func testNoConfigurationAndAnUnconfiguredAccountAreRefused_withoutConnecting() async throws {
        let opened = Opened()
        let none = try environment(config: nil, opened: opened)
        let first = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "draft_id": .string("5")], none)
        XCTAssertTrue(first?.contains("not configured") == true, first ?? "not refused")
        let other = try environment(config: config, opened: opened)
        let second = await failure(["account_name": .string("someone@else.example"), "draft_id": .string("5")], other)
        XCTAssertTrue(second?.contains("not configured for someone@else.example") == true, second ?? "not refused")
        XCTAssertEqual(opened.count, 0)
    }

    func testAnUnreadableConfigurationIsRefused_notTreatedAsAbsent() async throws {
        let env = try environment(config: "{ not json")
        let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "draft_id": .string("5")], env)
        XCTAssertTrue(message?.contains("direct-transport.json: is not valid JSON") == true, message ?? "not refused")
    }

    func testAMissingCredentialIsRefusedNamingTheCommandLineMode_withoutConnecting() async throws {
        let opened = Opened()
        let env = try environment(config: config, password: nil, opened: opened)
        let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "draft_id": .string("5")], env)
        XCTAssertTrue(message?.contains("--direct-transport-set-credential 'me@icloud.example'") == true, message ?? "not refused")
        XCTAssertEqual(opened.count, 0)
    }

    /// #748: the session's notes on how each mailbox was found reach the result,
    /// through the protocol (a default in an extension alone would drop them).
    func testTheSessionsMailboxNotesReachTheResult() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = [draft()]
        session.lookupNotes = ["The drafts mailbox is the one `drafts_mailbox` names in direct-transport.json."]
        let env = try environment(config: config, session: session, opened: Opened())
        let text = try await SendDraftTool.run(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "subject_match": .string("Report")], env)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let notes = try XCTUnwrap(object["notes"] as? [String])
        XCTAssertTrue(notes.contains(session.lookupNotes[0]), "\(notes)")
    }

    func testASentDraftReturnsTheOutcomeAndStages_andThePasswordAppearsNowhere() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = [draft()]
        let opened = Opened()
        let env = try environment(config: config, session: session, opened: opened)
        let text = try await SendDraftTool.run(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "subject_match": .string("Report")], env)
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

    /// Scenario: The description carries the caveat.
    func testTheListedDescriptionSaysItHasNotRunAgainstARealServer_andNamesTheIssue() throws {
        let tool = try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == "send_draft" })
        let text = try XCTUnwrap(tool.description)
        XCTAssertTrue(text.contains("NOT YET RUN AGAINST A REAL MAIL SERVER"), text)
        XCTAssertTrue(text.contains("#742"), text)
        XCTAssertEqual(ToolAccess.of("send_draft"), .send)
    }

    /// The submission lock covers the whole call: a second call is refused
    /// before it connects to anything.
    func testASecondCallIsRefusedBeforeItConnects() async throws {
        let opened = Opened()
        let env = try environment(config: config, opened: opened)
        let records = SendRecordStore(directory: env.stateDirectory)
        try await records.withSubmissionLock {
            let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                         "subject_match": .string("Report")], env)
            XCTAssertTrue(message?.contains("another send_draft or append_draft call is running") == true, message ?? "not refused")
        }
        XCTAssertEqual(opened.count, 0)
    }

    func testANameThatIsNoConfiguredAccountDoesNotVetoTheID() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = [draft()]
        let env = try environment(config: config, session: session)
        let text = try await SendDraftTool.run(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                                "account_name": .string("iCloud"), "subject_match": .string("Report")], env)
        XCTAssertTrue(text.contains("\"submitted\""), text)
    }

    func testAccountIDAndNameThatNameDifferentAccountsAreRefused() async throws {
        let env = try environment(config: config)
        let two = """
        {"accounts": [{"account_id": "AAAAAAAA-2222-4333-8444-555555555555", "address": "me@icloud.example",
          "smtp": {"host": "smtp.example", "port": 587}, "imap": {"host": "imap.example", "port": 993},
          "sent_copy": "append", "allowed_from": []},
         {"account_id": "BBBBBBBB-2222-4333-8444-555555555555", "address": "other@icloud.example",
          "smtp": {"host": "smtp.example", "port": 587}, "imap": {"host": "imap.example", "port": 993},
          "sent_copy": "append", "allowed_from": []}]}
        """
        let both = try environment(config: two)
        let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"),
                                     "account_name": .string("other@icloud.example"),
                                     "subject_match": .string("Report")], both)
        XCTAssertTrue(message?.contains("different accounts") == true, message ?? "not refused")
    }

    func testARefusalFromTheFlowIsReportedAsTheToolError() async throws {
        let session = SendDraftFlowTests.FakeSession()
        session.drafts = []
        let env = try environment(config: config, session: session)
        let message = await failure(["account_id": .string("AAAAAAAA-2222-4333-8444-555555555555"), "subject_match": .string("Report")], env)
        XCTAssertTrue(message?.contains("no draft in the server's drafts mailbox matched") == true, message ?? "not refused")
    }
}
