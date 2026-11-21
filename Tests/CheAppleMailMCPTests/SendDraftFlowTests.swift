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
        /// What `appendDraft` answers (#744).
        var appendDraftOutcome: AppendOutcome = .appended(uid: 1, uidValidity: 1)
        /// The server stores the draft although the outcome says otherwise.
        var storeDraftDespiteOutcome = false
        var searchError: Error?
        /// The name `draftsMailbox` answers.
        var draftsMailboxName = "Drafts"
        /// Extra hits a Message-ID search returns, as IMAP's substring match would (#744).
        var nearMissHits: [DraftSummary] = []
        private(set) var appendedDrafts: [Data] = []
        /// The mailbox of every Message-ID search, in order.
        private(set) var searchedMailboxes: [String] = []
        var removeError: Error?
        var expungeOne = true
        var draftsMailboxError: Error?
        var prepareError: Error?
        var sentHasCopy = false
        /// Replaces what fetch returns, to show a draft that changed after the search.
        var fetchOverride: FetchedDraft?
        /// Runs inside submit, after the record is claimed.
        var onSubmit: (() -> Void)?
        /// Runs after a successful append.
        var onAppend: (() -> Void)?
        /// What the sent mailbox holds: every message stored by append.
        private(set) var sentMailboxContents: [Data] = []
        private(set) var calls: [String] = []
        private(set) var submitted: [(message: Data, from: String, to: [String])] = []

        private func note(_ call: String) { lock.withLock { calls.append(call) } }

        func draftsMailbox() async throws -> String {
            note("draftsMailbox")
            if let draftsMailboxError { throw draftsMailboxError }
            return draftsMailboxName
        }
        func sentMailbox() async throws -> String { note("sentMailbox"); return "Sent Messages" }
        func drafts(withMessageID messageID: String, in mailbox: String) async throws -> [DraftSummary] {
            note("searchMessageID")
            lock.withLock { searchedMailboxes.append(mailbox) }
            if let searchError { throw searchError }
            return drafts.filter { $0.messageID == messageID }.map { DraftSummary(uid: $0.uid, subject: $0.subject, messageID: $0.messageID) }
                + nearMissHits
        }
        func drafts(withSubjectContaining subject: String, in mailbox: String) async throws -> [DraftSummary] {
            note("searchSubject")
            // IMAP SEARCH SUBJECT "" matches every message; Swift's contains("") is false.
            return drafts.filter { subject.isEmpty || $0.subject.contains(subject) }.map { DraftSummary(uid: $0.uid, subject: $0.subject, messageID: $0.messageID) }
        }
        func fetchDraft(_ summary: DraftSummary, in mailbox: String) async throws -> FetchedDraft {
            note("fetch")
            if let fetchOverride { return fetchOverride }
            return try XCTUnwrap(drafts.first { $0.uid == summary.uid })
        }
        func sentCopyExists(messageID: String, in mailbox: String) async throws -> Bool {
            note("sentLookup")
            return sentHasCopy
        }
        func prepareSubmission() async throws {
            note("prepare")
            if let prepareError { throw prepareError }
        }
        func submit(_ message: Data, from sender: String, to recipients: [String]) async -> SubmitOutcome {
            note("submit")
            onSubmit?()
            lock.withLock { submitted.append((message, sender, recipients)) }
            return submitOutcome
        }
        func appendSentCopy(_ message: Data, to mailbox: String) async throws {
            note("append:\(mailbox)")
            if let appendError { throw appendError }
            lock.withLock { sentMailboxContents.append(message) }
            onAppend?()
        }
        func appendDraft(_ message: Data, to mailbox: String) async -> AppendOutcome {
            note("appendDraft:\(mailbox)")
            var stored = storeDraftDespiteOutcome
            if case .appended = appendDraftOutcome { stored = true }
            if stored {
                // The envelope a server would report, read from the header.
                let fields = (try? BccRemoval.fields(in: message)) ?? []
                func value(_ name: String) -> String? {
                    fields.first { $0.name.lowercased() == name }?.value.trimmingCharacters(in: .whitespaces)
                }
                func addresses(_ name: String) -> [String] {
                    (value(name) ?? "").split(separator: ",").map { part -> String in
                        let text = part.trimmingCharacters(in: .whitespaces)
                        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
                            return String(text[text.index(after: open)..<close])
                        }
                        return text
                    }.filter { !$0.isEmpty }
                }
                let draft = FetchedDraft(uid: UInt32(drafts.count + 1), message: message, messageID: value("message-id"),
                                         subject: value("subject") ?? "", from: addresses("from"),
                                         recipients: addresses("to") + addresses("cc") + addresses("bcc"),
                                         hasInvalidRecipient: false)
                lock.withLock {
                    appendedDrafts.append(message)
                    drafts.append(draft)
                }
            }
            return appendDraftOutcome
        }
        func canExpungeOneMessage() async -> Bool { expungeOne }
        func removeDraft(_ draft: FetchedDraft, in mailbox: String) async throws {
            note("remove:\(draft.uid)")
            if let removeError { throw removeError }
            lock.withLock { drafts.removeAll { $0.uid == draft.uid } }
        }
        /// Runs inside close, which the tools call while they still hold the lock.
        var onClose: (() async -> Void)?
        func close() async { await onClose?() }
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

    /// The checks run in the spec's order, and the SMTP connection is opened
    /// only after all of them pass.
    func testTheChecksRunInOrder_beforeAnySMTPConnection() async {
        let session = FakeSession()
        session.drafts = [draft(from: ["stranger@x.example"], to: [])]   // fails checks 3 and 4
        let (flow, _) = flow(session)
        let message = await refusal { try await flow.run(.subject("Report")) }
        XCTAssertTrue(message?.contains("stranger@x.example") == true, "check 3 comes first: \(message ?? "not refused")")
        XCTAssertFalse(session.calls.contains("prepare"))
    }

    func testAMessageIDOutsidePrintableASCIIIsRefused() async {
        let session = FakeSession()
        session.drafts = [draft(id: "<d\u{1}1@icloud.example>")]
        let (flow, _) = flow(session, localID: nil)
        let message = await refusal { try await flow.run(.subject("Report")) }
        XCTAssertTrue(message?.contains("printable ASCII") == true, message ?? "not refused")
    }

    func testAnEmptySubjectSelectsTheDraftWhoseSubjectIsEmpty() async throws {
        let session = FakeSession()
        session.drafts = [draft(subject: "")]
        let (flow, _) = flow(session)
        let result = try await flow.run(.subject(""))
        XCTAssertEqual(result.outcome, .submitted)
    }

    func testACanonicallyEquivalentSubjectIsNotAnExactMatch() async {
        let session = FakeSession()
        session.drafts = [draft(subject: "Cafe\u{0301}")]                // e + combining accent
        let (flow, _) = flow(session)
        let message = await refusal { try await flow.run(.subject("Caf\u{00E9}")) }   // precomposed
        XCTAssertTrue(message?.contains("no draft") == true, message ?? "matched")
    }

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
            XCTAssertEqual(session.drafts.isEmpty, removed, "\(label): the draft on the server")
            if outcome != .submitted {
                XCTAssertEqual(result.sentCopy, .notAttempted, label)
                XCTAssertEqual(result.draftRemoval, .notAttempted, label)
            }
        }
    }

    /// spec-example: direct-transport / submission outcomes
    /// The authentication row: the login fails when the SMTP connection is
    /// opened, before any record is written or any transaction started.
    func testAnSMTPLoginFailureIsNotSent_withNoEntryAndNoTransaction() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.prepareError = Boom()
        let (flow, records) = flow(session)
        let result = try await flow.run(.subject("Report"))
        XCTAssertEqual(result.outcome, .notSent)
        XCTAssertNil(try records.entry(for: "<d1@icloud.example>"))
        XCTAssertFalse(session.calls.contains("submit"))
        XCTAssertEqual(result.sentCopy, .notAttempted)
        XCTAssertTrue(result.notes.contains(SendDraftFlow.localIndexNote))
        XCTAssertEqual(session.drafts.count, 1, "the draft stays on the server")
    }

    func testAPendingStageIsNotDoneUnderALoginThatDiffersOnlyInCase() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.appendError = Boom()
        let (flow, records) = flow(session)
        _ = try await flow.run(.subject("Report"))
        session.appendError = nil
        let recased = DirectTransportConfig.Account(accountID: "UUID-I", address: "ME@icloud.example",
                                                    smtp: account.smtp, imap: account.imap, sentCopy: .append,
                                                    allowedFrom: ["me@icloud.example"])
        let other = SendDraftFlow(account: recased, session: session, records: records,
                                  localMessageID: { _ in nil }, now: { Date() })
        let message = await refusal { try await other.run(.subject("Report")) }
        XCTAssertTrue(message?.contains("another account or server") == true, message ?? "not refused")
    }

    func testEveryResultSaysTheLocalIndexIsNotChanged() async throws {
        for transport in [SubmitOutcome.notAccepted(reply: "550 no"), .unknown(detail: "lost")] {
            let session = FakeSession()
            session.drafts = [draft()]
            session.submitOutcome = transport
            let (flow, _) = flow(session)
            let notes = try await flow.run(.subject("Report")).notes
            XCTAssertTrue(notes.contains(SendDraftFlow.localIndexNote), "\(transport)")
        }
    }

    func testAKnownOutcomeIsReported_evenWhenTheRecordCannotBeUpdated() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        let (flow, records) = flow(session)
        // After the claim, make the state directory unwritable.
        let dir = records.directory.path
        session.onSubmit = { _ = Darwin.chmod(dir, 0o500) }
        addTeardownBlock { _ = Darwin.chmod(dir, 0o700) }
        let result = try await flow.run(.subject("Report"))
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(result.sentCopy, .pending)
        XCTAssertEqual(result.draftRemoval, .pending)
        XCTAssertFalse(session.calls.contains { $0.hasPrefix("append:") || $0.hasPrefix("remove:") })
        XCTAssertTrue(result.notes.joined().contains("could not be updated"), result.notes.joined())
        _ = Darwin.chmod(dir, 0o700)
        XCTAssertEqual(try records.entry(for: "<d1@icloud.example>")?.effectiveState, .unknown,
                       "the entry still says attempting, so the draft is never submitted again")
    }

    func testAnUnknownOutcomeSaysSo_andNeverSaysSentOrNotSent() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.submitOutcome = .unknown(detail: "connection lost")
        let (flow, _) = flow(session)
        let text = try await flow.run(.subject("Report")).notes.joined(separator: " ")
        XCTAssertTrue(text.contains("UNKNOWN") && text.contains("NOT retrying"), text)
        // Quoted: unquoted, zsh reads the angle brackets as redirections.
        XCTAssertTrue(text.contains("--direct-transport-forget '<d1@icloud.example>'"), text)
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
            XCTAssertEqual(session.drafts.isEmpty, row.removal == .done, "row \(index): the draft on the server")
            // The sent copy is the draft as fetched, Bcc included.
            XCTAssertEqual(session.sentMailboxContents, row.copy == .done ? [draft().message] : [], "row \(index)")
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

    func testAPendingStageNeedsNoSMTPConnection() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.appendError = Boom()
        let (flow, _) = flow(session)
        _ = try await flow.run(.subject("Report"))
        session.appendError = nil
        session.prepareError = Boom()     // SMTP is down now
        let second = try await flow.run(.subject("Report"))
        XCTAssertEqual(second.sentCopy, .done)
        XCTAssertEqual(session.calls.filter { $0 == "prepare" }.count, 1, "only the first call opened SMTP")
    }

    func testAPendingStageIsDoneOnlyForTheSameAccountAndTheSameBytes() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.appendError = Boom()
        let (flow, records) = flow(session)
        _ = try await flow.run(.subject("Report"))
        session.appendError = nil
        let appendsBefore = session.calls.filter { $0.hasPrefix("append:") }.count

        let other = DirectTransportConfig.Account(accountID: "UUID-OTHER", address: "me@icloud.example",
                                                  smtp: account.smtp, imap: account.imap, sentCopy: .append, allowedFrom: [])
        let fromOther = SendDraftFlow(account: other, session: session, records: records,
                                      localMessageID: { _ in nil }, now: { Date() })
        let first = await refusal { try await fromOther.run(.subject("Report")) }
        XCTAssertTrue(first?.contains("another account") == true, first ?? "not refused")

        session.drafts = [draft(text: "From: me@icloud.example\r\nTo: me@icloud.example\r\nSubject: Report\r\n\r\nedited")]
        let second = await refusal { try await flow.run(.subject("Report")) }
        XCTAssertTrue(second?.contains("bytes changed") == true, second ?? "not refused")
        XCTAssertEqual(session.calls.filter { $0.hasPrefix("append:") }.count, appendsBefore, "nothing was stored")
        XCTAssertEqual(try records.entry(for: "<d1@icloud.example>")?.sentCopy, .pending)
    }

    /// The sent copy is stored but the record cannot say so: the draft, the only
    /// other source of those bytes, is kept.
    func testTheDraftIsKeptWhenTheStoredCopyCannotBeRecorded() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        let (flow, records) = flow(session)
        let dir = records.directory.path
        session.onAppend = { _ = Darwin.chmod(dir, 0o500) }
        addTeardownBlock { _ = Darwin.chmod(dir, 0o700) }
        let result = try await flow.run(.subject("Report"))
        _ = Darwin.chmod(dir, 0o700)
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(result.draftRemoval, .pending)
        XCTAssertFalse(session.calls.contains("remove:7"))
        XCTAssertFalse(session.drafts.isEmpty)
    }

    func testAProviderSentCopyStaysSkipped_whenTheAcceptanceCannotBeRecorded() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        let provider = DirectTransportConfig.Account(accountID: "UUID-I", address: "me@icloud.example",
                                                     smtp: account.smtp, imap: account.imap, sentCopy: .provider, allowedFrom: [])
        let (flow, records) = flow(session, account: provider)
        let dir = records.directory.path
        session.onSubmit = { _ = Darwin.chmod(dir, 0o500) }
        addTeardownBlock { _ = Darwin.chmod(dir, 0o700) }
        let result = try await flow.run(.subject("Report"))
        _ = Darwin.chmod(dir, 0o700)
        XCTAssertEqual(result.sentCopy, .skipped)
    }

    func testAPendingStageIsDoneOnlyOnTheServerItWasSubmittedFrom() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.appendError = Boom()
        let (flow, records) = flow(session)
        _ = try await flow.run(.subject("Report"))
        session.appendError = nil
        let moved = DirectTransportConfig.Account(accountID: "UUID-I", address: "me@icloud.example",
                                                  smtp: account.smtp, imap: .init(host: "other-imap", port: 993),
                                                  sentCopy: .append, allowedFrom: [])
        let elsewhere = SendDraftFlow(account: moved, session: session, records: records,
                                      localMessageID: { _ in nil }, now: { Date() })
        let message = await refusal { try await elsewhere.run(.subject("Report")) }
        XCTAssertTrue(message?.contains("another account or server") == true, message ?? "not refused")
    }

    func testACopyAlreadyInTheSentMailboxIsNotStoredTwice() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.sentHasCopy = true
        let (flow, _) = flow(session)
        let result = try await flow.run(.subject("Report"))
        XCTAssertEqual(result.sentCopy, .done)
        XCTAssertFalse(session.calls.contains { $0.hasPrefix("append:") })
    }

    /// The removal happened but its reply was lost: the draft is gone and the
    /// entry still says pending. A call by the local row records it as done.
    func testARemovalWhoseReplyWasLostIsRecordedWhenTheDraftIsGone() async throws {
        let session = FakeSession()
        session.drafts = [draft()]
        session.removeError = Boom()
        let (flow, records) = flow(session)
        _ = try await flow.run(.localRow(5))
        session.drafts = []
        let result = try await flow.run(.localRow(5))
        XCTAssertTrue(result.resumed)
        XCTAssertEqual(result.draftRemoval, .done)
        XCTAssertEqual(try records.entry(for: "<d1@icloud.example>")?.draftRemoval, .done)
        XCTAssertEqual(session.calls.filter { $0 == "submit" }.count, 1)
    }

    func testADraftThatChangedBetweenTheSearchAndTheFetchIsRefused() async {
        let session = FakeSession()
        session.drafts = [draft()]
        session.fetchOverride = draft(id: "<other@icloud.example>")
        let (flow, _) = flow(session)
        let message = await refusal { try await flow.run(.localRow(5)) }
        XCTAssertTrue(message?.contains("not the one the search found") == true, message ?? "not refused")
        XCTAssertFalse(session.calls.contains("submit"))
    }

    func testAFromWithTextThatIsNotAnAddressIsRefusedAsTheSender() async {
        let session = FakeSession()
        var bad = draft()
        bad.hasInvalidSender = true
        session.drafts = [bad]
        let (flow, _) = flow(session)
        let message = await refusal { try await flow.run(.subject("Report")) }
        XCTAssertTrue(message?.contains("From") == true, message ?? "not refused")
    }

    /// Two calls for the same draft cannot both submit it: the record is claimed
    /// in one step before the transaction.
    // MARK: - #745, a draft in Mail's draft layout

    private let mailDraftText = "Subject: Report\r\nMime-Version: 1.0 (Mac OS X Mail 16.0)\r\nContent-Type: multipart/alternative;\r\n\tboundary=\"B\"\r\nFrom: me@icloud.example\r\nMessage-Id: <d1@icloud.example>\r\nX-Uniform-Type-Identifier: com.apple.mail-draft\r\nTo: me@icloud.example\r\n\r\n--B\r\nContent-Type: text/plain\r\n\r\n\r\n--B--\r\n"

    func testADraftInMailsDraftLayoutIsRefused_beforeTheRecordOrAnySMTPConnection() async throws {
        let session = FakeSession()
        session.drafts = [draft(text: mailDraftText)]
        let (flow, records) = flow(session)
        let message = await refusal { try await flow.run(.subject("Report")) }
        XCTAssertTrue(message?.contains("Mail's draft layout") == true, message ?? "not refused")
        XCTAssertTrue(message?.contains("append_draft") == true, "it says how to make a draft that can be sent")
        XCTAssertTrue(message?.contains("Nothing was submitted") == true)
        XCTAssertFalse(session.calls.contains("prepare"), "no SMTP connection")
        XCTAssertFalse(session.calls.contains("submit"))
        XCTAssertNil(try records.entry(for: "<d1@icloud.example>"), "no entry was claimed")
    }

    func testTheMarkIsRecognisedWithoutRegardToCaseOrSpace_andOnlyThatValueIsRefused() async throws {
        for header in ["x-uniform-type-identifier:   COM.APPLE.MAIL-DRAFT  ", "X-Uniform-Type-Identifier:\r\n com.apple.mail-draft"] {
            let session = FakeSession()
            session.drafts = [draft(text: "From: me@icloud.example\r\nTo: me@icloud.example\r\n\(header)\r\nSubject: Report\r\n\r\nbody")]
            let (flow, _) = flow(session)
            let message = await refusal { try await flow.run(.subject("Report")) }
            XCTAssertTrue(message?.contains("Mail's draft layout") == true, "\(header.debugDescription): \(message ?? "not refused")")
        }
        let other = FakeSession()
        other.drafts = [draft(text: "From: me@icloud.example\r\nTo: me@icloud.example\r\nX-Uniform-Type-Identifier: com.apple.mail-message\r\nSubject: Report\r\n\r\nbody")]
        let (flow, _) = flow(other)
        let result = try await flow.run(.subject("Report"))
        XCTAssertEqual(result.outcome, .submitted, "another value of the field is not Mail's draft mark")
    }

    func testAPendingStageOfADraftInMailsLayoutIsStillCompleted() async throws {
        // Submitted before the check existed: its pending stages must not be stranded.
        let session = FakeSession()
        let stored = draft(text: mailDraftText)
        session.drafts = [stored]
        let (flow, records) = flow(session)
        try records.put(SendRecord(messageID: "<d1@icloud.example>", accountID: account.accountID, state: .submitted,
                                   sentCopy: .pending, draftRemoval: .pending, updatedAt: Date(), serverReply: "250 OK",
                                   submittedAt: Date(), draftDigest: stored.digest, server: SendDraftFlow.server(of: account)))
        let result = try await flow.run(.subject("Report"))
        XCTAssertTrue(result.resumed)
        XCTAssertEqual(result.sentCopy, .done)
        XCTAssertFalse(session.calls.contains("submit"))
    }

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
