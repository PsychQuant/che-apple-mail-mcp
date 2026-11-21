import XCTest
@testable import CheAppleMailMCP

/// #742 — the steps of `send_draft` against a stand-in server: no network, no Mail.
final class SendDraftFlowTests: XCTestCase {

    /// A server that answers from fixed data and records what it was asked to do.
    final class FakeSession: DirectTransportSession, @unchecked Sendable {
        private let lock = NSLock()
        var drafts: [FetchedDraft] = []
        var submitOutcome: SubmitOutcome = .accepted(reply: "250 2.0.0 OK")
        var appendError: Error?
        var removeError: Error?
        var expungeOne = true
        var draftsMailboxError: Error?
        private(set) var calls: [String] = []
        private(set) var submitted: [(message: Data, from: String, to: [String])] = []

        private func note(_ call: String) { lock.withLock { calls.append(call) } }

        func draftsMailbox() async throws -> String {
            note("draftsMailbox")
            if let draftsMailboxError { throw draftsMailboxError }
            return "Drafts"
        }
        func sentMailbox() async throws -> String { note("sentMailbox"); return "Sent Messages" }
        func drafts(withMessageID messageID: String, in mailbox: String) async throws -> [DraftSummary] {
            note("searchMessageID")
            return drafts.filter { $0.messageID == messageID }.map { DraftSummary(uid: $0.uid, subject: $0.subject, messageID: $0.messageID) }
        }
        func drafts(withSubjectContaining subject: String, in mailbox: String) async throws -> [DraftSummary] {
            note("searchSubject")
            return drafts.filter { $0.subject.contains(subject) }.map { DraftSummary(uid: $0.uid, subject: $0.subject, messageID: $0.messageID) }
        }
        func fetchDraft(uid: UInt32, in mailbox: String) async throws -> FetchedDraft {
            note("fetch")
            return try XCTUnwrap(drafts.first { $0.uid == uid })
        }
        func submit(_ message: Data, from sender: String, to recipients: [String]) async -> SubmitOutcome {
            note("submit")
            lock.withLock { submitted.append((message, sender, recipients)) }
            return submitOutcome
        }
        func appendSentCopy(_ message: Data, to mailbox: String) async throws {
            note("append:\(mailbox)")
            if let appendError { throw appendError }
        }
        func canExpungeOneMessage() async -> Bool { expungeOne }
        func removeDraft(uid: UInt32, in mailbox: String) async throws {
            note("remove:\(uid)")
            if let removeError { throw removeError }
        }
        func close() async {}
    }

    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

    private let account = DirectTransportConfig.Account(
        accountID: "UUID-I", address: "me@icloud.example",
        smtp: .init(host: "smtp", port: 587), imap: .init(host: "imap", port: 993),
        sentCopy: .append, allowedFrom: ["alias@icloud.example"])

    private func draft(uid: UInt32 = 7, id: String? = "<d1@icloud.example>", subject: String = "Report",
                       from: [String] = ["me@icloud.example"], to: [String] = ["me@icloud.example"],
                       invalid: Bool = false,
                       text: String = "From: me@icloud.example\r\nTo: me@icloud.example\r\nBcc: hidden@icloud.example\r\nSubject: Report\r\n\r\nbody") -> FetchedDraft {
        FetchedDraft(uid: uid, message: Data(text.utf8), messageID: id, subject: subject, from: from,
                     recipients: to, hasInvalidRecipient: invalid)
    }

    private func flow(_ session: FakeSession, account: DirectTransportConfig.Account? = nil,
                      localID: String? = "<d1@icloud.example>") -> (SendDraftFlow, SendRecordStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dt-flow-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let records = SendRecordStore(directory: dir)
        return (SendDraftFlow(account: account ?? self.account, session: session, records: records,
                              localMessageID: { _ in localID }, now: { Date(timeIntervalSince1970: 1_800_000_000) }),
                records)
    }

    private func refusal(_ body: () async throws -> SendDraftResult) async -> String? {
        do { _ = try await body(); return nil } catch { return "\(error)" }
    }

    // MARK: - Selecting the draft

    func testADraftIsSelectedByExactSubject_notBySubstring() async throws {
        let session = FakeSession()
        session.drafts = [draft(uid: 1, id: "<a@x>", subject: "Report"), draft(uid: 2, id: "<b@x>", subject: "Report 2")]
        let (flow, _) = flow(session)
        let result = try await flow.run(.subject("Report"))
        XCTAssertEqual(result.messageID, "<a@x>")
    }

    func testTwoDraftsWithTheSubjectAreRefused_andNothingIsSubmitted() async {
        let session = FakeSession()
        session.drafts = [draft(uid: 1, id: "<a@x>"), draft(uid: 2, id: "<b@x>")]
        let (flow, _) = flow(session)
        let message = await refusal { try await flow.run(.subject("Report")) }
        XCTAssertTrue(message?.contains("2 drafts") == true, message ?? "not refused")
        XCTAssertFalse(session.calls.contains("submit"))
    }

    func testALocalRowIsFoundOnTheServerByItsMessageID() async throws {
        let session = FakeSession()
        session.drafts = [draft(uid: 1, id: "<other@x>"), draft(uid: 9, id: "<d1@icloud.example>")]
        let (flow, _) = flow(session)
        let result = try await flow.run(.localRow(42))
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertTrue(session.calls.contains("remove:9"))
    }

    func testADraftThatIsNotOnTheServerIsRefused() async {
        let session = FakeSession()
        session.drafts = [draft(id: "<other@x>")]
        let (flow, _) = flow(session)
        let message = await refusal { try await flow.run(.localRow(42)) }
        XCTAssertTrue(message?.contains("no draft in the server's drafts mailbox matched") == true, message ?? "not refused")
        XCTAssertFalse(session.calls.contains("submit"))
    }

    // MARK: - The checks before submission, in order

    func testTheChecksRefuseBeforeSubmitting() async {
        let cases: [(FetchedDraft, String)] = [
            (draft(id: nil), "no Message-ID"),
            (draft(from: ["stranger@x.example"]), "stranger@x.example"),
            (draft(from: ["me@icloud.example", "alias@icloud.example"]), "not one address"),
            (draft(to: []), "names no recipient"),
            (draft(invalid: true), "not an address"),
            (draft(text: "To: me@icloud.example\r\nResent-Bcc: x@x\r\n\r\nbody"), "Resent-Bcc"),
        ]
        for (fetched, word) in cases {
            let session = FakeSession()
            session.drafts = [fetched]
            let (flow, records) = flow(session)
            let message = await refusal { try await flow.run(.subject("Report")) }
            XCTAssertTrue(message?.contains(word) == true, "\(word): \(message ?? "not refused")")
            XCTAssertFalse(session.calls.contains("submit"), word)
            if let id = fetched.messageID { XCTAssertNil(try records.entry(for: id), word) }
        }
    }

    func testAnAllowedAliasMaySend_comparedWithoutCase() async throws {
        let session = FakeSession()
        session.drafts = [draft(from: ["ALIAS@icloud.example"])]
        let (flow, _) = flow(session)
        let result = try await flow.run(.subject("Report"))
        XCTAssertEqual(result.outcome, .submitted)
    }

    // MARK: - What is submitted

    func testTheSubmittedBytesAreTheDraftWithoutBcc_andBccIsAnEnvelopeRecipient() async throws {
        let session = FakeSession()
        session.drafts = [draft(to: ["me@icloud.example", "hidden@icloud.example"])]
        let (flow, _) = flow(session)
        _ = try await flow.run(.subject("Report"))
        let sent = try XCTUnwrap(session.submitted.first)
        XCTAssertEqual(String(decoding: sent.message, as: UTF8.self),
                       "From: me@icloud.example\r\nTo: me@icloud.example\r\nSubject: Report\r\n\r\nbody")
        XCTAssertEqual(sent.from, "me@icloud.example")
        XCTAssertEqual(sent.to, ["me@icloud.example", "hidden@icloud.example"])
        XCTAssertTrue(session.calls.contains("append:Sent Messages"), "the sent copy keeps the draft's bytes")
    }

    // MARK: - Submission outcomes

    // spec-example: direct-transport / submission outcomes
    func testEverySubmissionOutcomeRow() async throws {
        let rows: [(String, SubmitOutcome, SendDraftResult.Outcome, SendRecord.State?, Bool)] = [
            ("final 250", .accepted(reply: "250 OK"), .submitted, .submitted, true),
            ("authentication failed before the transaction", .notAccepted(reply: nil), .notSent, nil, false),
            ("recipient rejected with 550", .notAccepted(reply: "550 no such user"), .notSent, nil, false),
            ("final 552 after the content", .notAccepted(reply: "552 too big"), .notSent, nil, false),
            ("final 451 after the content", .notAccepted(reply: "451 try later"), .notSent, nil, false),
            ("connection lost after the content", .unknown(detail: "connection lost"), .unknown, .unknown, false),
            ("timeout waiting for the final reply", .unknown(detail: "timed out"), .unknown, .unknown, false),
            ("an error the tool does not recognise", .unknown(detail: "transport error"), .unknown, .unknown, false),
        ]
        for (label, transport, outcome, entryAfter, removed) in rows {
            let session = FakeSession()
            session.drafts = [draft()]
            session.submitOutcome = transport
            let (flow, records) = flow(session)
            let result = try await flow.run(.subject("Report"))
            XCTAssertEqual(result.outcome, outcome, label)
            XCTAssertEqual(try records.entry(for: "<d1@icloud.example>")?.state, entryAfter, label)
            XCTAssertEqual(session.calls.contains("remove:7"), removed, label)
            if outcome != .submitted {
                XCTAssertEqual(result.sentCopy, .notAttempted, label)
                XCTAssertEqual(result.draftRemoval, .notAttempted, label)
            }
        }
    }

    func testAnUnknownOutcomeSaysSo_andNeverSaysSentOrNotSent() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.submitOutcome = .unknown(detail: "connection lost")
        let (flow, _) = flow(session)
        let text = try await flow.run(.subject("Report")).notes.joined(separator: " ")
        XCTAssertTrue(text.contains("UNKNOWN") && text.contains("NOT retrying"), text)
        XCTAssertTrue(text.contains("--direct-transport-forget <d1@icloud.example>"), text)
        for word in ["was sent", "not sent", "has been sent", "delivered"] {
            XCTAssertFalse(text.lowercased().contains(word), word)
        }
    }

    func testAfterAnUnknownOrAnInterruptedSubmissionTheDraftIsRefused() async throws {
        for state in [SendRecord.State.unknown, .attempting] {
            let session = FakeSession()
            session.drafts = [draft()]
            let (flow, records) = flow(session)
            try records.put(SendRecord(messageID: "<d1@icloud.example>", accountID: "UUID-I", state: state,
                                       sentCopy: .pending, draftRemoval: .pending, updatedAt: Date(), serverReply: nil))
            let message = await refusal { try await flow.run(.subject("Report")) }
            XCTAssertTrue(message?.contains("UNKNOWN") == true, "\(state): \(message ?? "not refused")")
            XCTAssertFalse(session.calls.contains("submit"), "\(state)")
        }
    }

    func testADraftAlreadySubmittedWithNothingPendingIsRefused() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        let (flow, records) = flow(session)
        try records.put(SendRecord(messageID: "<d1@icloud.example>", accountID: "UUID-I", state: .submitted,
                                   sentCopy: .done, draftRemoval: .done, updatedAt: Date(timeIntervalSince1970: 0), serverReply: nil))
        let message = await refusal { try await flow.run(.subject("Report")) }
        XCTAssertTrue(message?.contains("already submitted") == true, message ?? "not refused")
        XCTAssertFalse(session.calls.contains("submit"))
    }

    // MARK: - Stages after submission

    // spec-example: direct-transport / stages after submission
    func testEveryStageRow() async throws {
        struct Row { let sentCopy: DirectTransportConfig.SentCopy; let appendFails: Bool; let removeFails: Bool
            let expungeOne: Bool; let copy: SendDraftResult.StageResult; let removal: SendDraftResult.StageResult
            let removeAttempted: Bool }
        let rows = [
            Row(sentCopy: .append, appendFails: false, removeFails: false, expungeOne: true, copy: .done, removal: .done, removeAttempted: true),
            Row(sentCopy: .append, appendFails: true, removeFails: false, expungeOne: true, copy: .pending, removal: .pending, removeAttempted: false),
            Row(sentCopy: .append, appendFails: false, removeFails: true, expungeOne: true, copy: .done, removal: .pending, removeAttempted: true),
            Row(sentCopy: .provider, appendFails: false, removeFails: false, expungeOne: true, copy: .skipped, removal: .done, removeAttempted: true),
            Row(sentCopy: .append, appendFails: false, removeFails: false, expungeOne: false, copy: .done, removal: .pending, removeAttempted: false),
        ]
        for (index, row) in rows.enumerated() {
            let session = FakeSession()
            session.drafts = [draft()]
            session.appendError = row.appendFails ? Boom() : nil
            session.removeError = row.removeFails ? Boom() : nil
            session.expungeOne = row.expungeOne
            let acct = DirectTransportConfig.Account(accountID: "UUID-I", address: "me@icloud.example",
                                                     smtp: account.smtp, imap: account.imap,
                                                     sentCopy: row.sentCopy, allowedFrom: [])
            let (flow, _) = flow(session, account: acct)
            let result = try await flow.run(.subject("Report"))
            XCTAssertEqual(result.outcome, .submitted, "row \(index)")
            XCTAssertEqual(result.sentCopy, row.copy, "row \(index)")
            XCTAssertEqual(result.draftRemoval, row.removal, "row \(index)")
            XCTAssertEqual(session.calls.contains("remove:7"), row.removeAttempted, "row \(index)")
            XCTAssertEqual(session.calls.contains { $0.hasPrefix("append:") }, row.sentCopy == .append, "row \(index)")
            XCTAssertTrue(result.notes.contains { $0.contains("does not change the local mail index") }, "row \(index)")
        }
    }

    func testAPendingStageIsCompletedLater_withoutSubmittingAgain() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.appendError = Boom()
        let (flow, records) = flow(session)
        let first = try await flow.run(.subject("Report"))
        XCTAssertEqual(first.sentCopy, .pending)

        session.appendError = nil
        let second = try await flow.run(.subject("Report"))
        XCTAssertTrue(second.resumed)
        XCTAssertEqual(second.sentCopy, .done)
        XCTAssertEqual(second.draftRemoval, .done)
        XCTAssertEqual(session.calls.filter { $0 == "submit" }.count, 1, "submitted once only")
        XCTAssertEqual(try records.entry(for: "<d1@icloud.example>")?.draftRemoval, .done)
    }

    /// Two calls for the same draft cannot both submit it: the record is claimed
    /// in one step before the transaction.
    func testAClaimedDraftIsNotSubmittedASecondTime() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        let (flow, records) = flow(session)
        let other = SendRecord(messageID: "<d1@icloud.example>", accountID: "UUID-I", state: .attempting,
                               sentCopy: .pending, draftRemoval: .pending, updatedAt: Date(), serverReply: nil)
        XCTAssertNil(try records.claim(other))
        XCTAssertNotNil(try records.claim(other), "a second claim sees the first")
        let message = await refusal { try await flow.run(.subject("Report")) }
        XCTAssertNotNil(message)
        XCTAssertFalse(session.calls.contains("submit"))
    }
}
