import CryptoKit
import Foundation

/// What `send_draft` needs from the mail server (#742). The SwiftMail adapter
/// implements it; tests use a stand-in, so every branch of the flow runs
/// without a network.
protocol DirectTransportSession: Sendable {
    /// The mailbox the server marks `\Drafts`. Throws when it marks none or more than one.
    func draftsMailbox() async throws -> String
    /// The mailbox the server marks `\Sent`. Throws when it marks none or more than one.
    func sentMailbox() async throws -> String
    /// Drafts whose Message-ID header equals `messageID`.
    func drafts(withMessageID messageID: String, in mailbox: String) async throws -> [DraftSummary]
    /// Drafts whose subject contains `subject` (the server's search is a
    /// substring match; the flow keeps only exact matches).
    func drafts(withSubjectContaining subject: String, in mailbox: String) async throws -> [DraftSummary]
    /// Throws when the mailbox's UIDVALIDITY is no longer the summary's: the UID
    /// may then name another message.
    func fetchDraft(_ summary: DraftSummary, in mailbox: String) async throws -> FetchedDraft
    /// Whether the mailbox already holds a message with this Message-ID.
    func sentCopyExists(messageID: String, in mailbox: String) async throws -> Bool
    /// Connects and logs in to the SMTP server. Called only when a submission
    /// follows, after the checks and before the record is claimed.
    func prepareSubmission() async throws
    /// Never throws: every failure is classified into the outcome.
    func submit(_ message: Data, from sender: String, to recipients: [String]) async -> SubmitOutcome
    func appendSentCopy(_ message: Data, to mailbox: String) async throws
    /// Whether the server can expunge one message by its UID (UIDPLUS).
    func canExpungeOneMessage() async -> Bool
    /// Marks the one message deleted and expunges that message only. Throws when
    /// the mailbox's UIDVALIDITY is no longer the draft's.
    func removeDraft(_ draft: FetchedDraft, in mailbox: String) async throws
    func close() async
}

struct DraftSummary: Equatable, Sendable {
    let uid: UInt32
    let subject: String
    let messageID: String?
    /// The mailbox's UIDVALIDITY when the UID was read.
    var uidValidity: UInt32 = 1
}

/// A draft as fetched from the server: its bytes, and the addresses the
/// server's envelope reports for it.
struct FetchedDraft: Equatable, Sendable {
    let uid: UInt32
    let message: Data
    let messageID: String?
    let subject: String
    let from: [String]
    let recipients: [String]
    /// A recipient field holds text that is not an address, or a To, Cc or Bcc
    /// field in the header has no address in the server's envelope.
    let hasInvalidRecipient: Bool
    /// The From field holds text that is not an address, or is in the header
    /// with no address in the envelope.
    var hasInvalidSender = false
    /// The mailbox's UIDVALIDITY when the draft was fetched.
    var uidValidity: UInt32 = 1

    /// SHA-256 of the bytes, to tell later whether a draft is the one submitted.
    var digest: String { SHA256.hash(data: message).map { String(format: "%02x", $0) }.joined() }
}

enum SubmitOutcome: Equatable, Sendable {
    /// A final 2xx reply to the message.
    case accepted(reply: String)
    /// Provably not accepted: before the transaction, not received completely,
    /// or explicitly rejected with a final 4xx or 5xx reply.
    case notAccepted(reply: String?)
    /// Everything else.
    case unknown(detail: String)
}

/// How the caller chose the draft.
enum DraftSelector: Equatable {
    /// A local message row id; its Message-ID is read from the local store.
    case localRow(Int)
    case subject(String)
}

/// Why `send_draft` did not start a submission. Nothing was submitted for any of these.
struct SendDraftRefusal: Error, CustomStringConvertible {
    let description: String
}

/// The result of one `send_draft` call that reached the submission step or
/// resumed the stages after it.
struct SendDraftResult: Equatable {
    enum Outcome: String { case submitted, notSent = "not_sent", unknown }
    enum StageResult: String { case done, pending, skipped, notAttempted = "not_attempted" }

    let outcome: Outcome
    let messageID: String
    let serverReply: String?
    let sentCopy: StageResult
    let draftRemoval: StageResult
    /// True when this call only completed stages of an earlier submission.
    let resumed: Bool
    let notes: [String]
}

/// The steps of `send_draft`, in the order the spec gives them.
struct SendDraftFlow {
    let account: DirectTransportConfig.Account
    let session: DirectTransportSession
    let records: SendRecordStore
    /// Reads the Message-ID of a local message row; nil when it has none.
    let localMessageID: (Int) throws -> String?
    let now: () -> Date

    static let localIndexNote = "This tool does not change the local mail index; Mail shows the change when it next synchronises."

    /// One call at a time, from the first look at the record to the last write.
    func run(_ selector: DraftSelector) async throws -> SendDraftResult {
        try await records.withSubmissionLock { try await runHoldingTheLock(selector) }
    }

    private func runHoldingTheLock(_ selector: DraftSelector) async throws -> SendDraftResult {
        let draftsBox = try await session.draftsMailbox()
        var wantedID: String?
        let candidates: [DraftSummary]
        switch selector {
        case .localRow(let row):
            guard let id = try localMessageID(row), !id.isEmpty else {
                throw SendDraftRefusal(description: "the local message \(row) has no Message-ID to find it on the server by; nothing was submitted")
            }
            wantedID = id
            candidates = try await session.drafts(withMessageID: id, in: draftsBox).filter { $0.messageID == id }
        case .subject(let subject):
            candidates = try await session.drafts(withSubjectContaining: subject, in: draftsBox).filter { $0.subject == subject }
        }
        if candidates.isEmpty, let id = wantedID, let finished = try removalAlreadyHappened(id) {
            return finished
        }
        guard candidates.count == 1, let only = candidates.first else {
            throw SendDraftRefusal(description: candidates.isEmpty
                ? "no draft in the server's drafts mailbox matched; a draft that exists only on this Mac (not yet synchronised) cannot be sent this way. Nothing was submitted"
                : "\(candidates.count) drafts in the server's drafts mailbox matched; nothing was submitted")
        }
        let draft = try await session.fetchDraft(only, in: draftsBox)
        let stillTheSelection: Bool
        switch selector {
        case .localRow: stillTheSelection = draft.messageID == wantedID
        case .subject(let subject): stillTheSelection = draft.subject == subject && draft.messageID == only.messageID
        }
        guard stillTheSelection else {
            throw SendDraftRefusal(description: "the draft fetched is not the one the search found (it changed in between); nothing was submitted")
        }

        // Check 1: a Message-ID is the key of the record of sent drafts.
        guard let messageID = draft.messageID, !messageID.isEmpty else {
            throw SendDraftRefusal(description: "the draft has no Message-ID, so a second submission could not be prevented; nothing was submitted")
        }
        // Check 2: the record.
        if let existing = try records.entry(for: messageID) {
            switch existing.effectiveState {
            case .unknown, .attempting:
                throw SendDraftRefusal(description: "an earlier submission of this draft ended with its state UNKNOWN; the tool is NOT retrying. Check the recipients' mail or the sent mailbox, then, if it was not sent, \(DirectTransportCLI.forgetInstruction(for: messageID))")
            case .submitted:
                guard existing.sentCopy == .pending || existing.draftRemoval == .pending else {
                    throw SendDraftRefusal(description: "this draft was already submitted at \(Self.iso(existing.submittedAt ?? existing.updatedAt)); nothing was submitted")
                }
                guard DirectTransportConfig.equalIgnoringASCIICase(existing.accountID, account.accountID) else {
                    throw SendDraftRefusal(description: "this Message-ID was submitted from another account (\(existing.accountID)); its pending stages are done only from that account. Nothing was submitted")
                }
                guard existing.draftDigest == draft.digest else {
                    throw SendDraftRefusal(description: "the draft on the server is not the one that was submitted (its bytes changed), so its pending stages are not done; nothing was submitted. Delete or store it in Mail")
                }
                return try await finishStages(existing, draft: draft, draftsBox: draftsBox, resumed: true, notes: [])
            }
        }
        // Check 3: the sender.
        guard !draft.hasInvalidSender, draft.from.count == 1, let sender = draft.from.first, account.mayUseFrom(sender) else {
            let shown = draft.from.isEmpty ? "no address" : draft.from.joined(separator: ", ")
            throw SendDraftRefusal(description: "the draft's From (\(shown)) is not one address this account may send as; nothing was submitted")
        }
        // Check 4: the recipients.
        guard !draft.recipients.isEmpty else {
            throw SendDraftRefusal(description: "the draft names no recipient; nothing was submitted")
        }
        guard !draft.hasInvalidRecipient else {
            throw SendDraftRefusal(description: "a recipient field of the draft holds text that is not an address; nothing was submitted")
        }
        // Check 5: the header can be sent without its Bcc fields.
        let outgoing: Data
        do {
            outgoing = try BccRemoval.strip(draft.message)
        } catch {
            throw SendDraftRefusal(description: "\(error); nothing was submitted")
        }

        // The SMTP connection is opened only now, so a call that only completes
        // stages never needs it; a failure here is before the transaction.
        do {
            try await session.prepareSubmission()
        } catch {
            return SendDraftResult(outcome: .notSent, messageID: messageID, serverReply: nil,
                                   sentCopy: .notAttempted, draftRemoval: .notAttempted, resumed: false,
                                   notes: ["The SMTP connection or login failed (\(error)); the mail transaction was not started, nothing was submitted, and the draft is still in the drafts mailbox.",
                                           Self.localIndexNote])
        }

        let attempting = SendRecord(messageID: messageID, accountID: account.accountID, state: .attempting,
                                    sentCopy: account.sentCopy == .append ? .pending : .skipped,
                                    draftRemoval: .pending, updatedAt: now(), serverReply: nil,
                                    submittedAt: nil, draftDigest: draft.digest)
        if try records.claim(attempting) != nil {
            throw SendDraftRefusal(description: "another call is submitting this draft or has submitted it; nothing was submitted")
        }

        switch await session.submit(outgoing, from: sender, to: draft.recipients) {
        case .accepted(let reply):
            var record = attempting
            record.state = .submitted
            record.serverReply = reply
            record.submittedAt = now()
            record.updatedAt = record.submittedAt ?? now()
            do {
                try records.put(record)
            } catch {
                // The entry stays `attempting`, which a later call reads as unknown:
                // the draft is never submitted again, and the stages wait for a person.
                return SendDraftResult(outcome: .submitted, messageID: messageID, serverReply: reply,
                                       sentCopy: .pending, draftRemoval: .pending, resumed: false,
                                       notes: ["The server accepted the message, but the record of sent drafts could not be updated (\(error)). It still says the send is in progress, so later calls refuse this draft as UNKNOWN and never submit it again; the sent copy and the draft's removal were not attempted. Store and delete the draft in Mail.",
                                               Self.localIndexNote])
            }
            return try await finishStages(record, draft: draft, draftsBox: draftsBox, resumed: false, notes: [])
        case .notAccepted(let reply):
            var notes = ["The server did not accept the message. The draft is still in the drafts mailbox."]
            do {
                try records.remove(messageID)
            } catch {
                notes.append("The record of sent drafts could not be updated (\(error)), so it still says the send is in progress and later calls refuse this draft as UNKNOWN. It was not sent; \(DirectTransportCLI.forgetInstruction(for: messageID)) before trying again.")
            }
            return SendDraftResult(outcome: .notSent, messageID: messageID, serverReply: reply,
                                   sentCopy: .notAttempted, draftRemoval: .notAttempted, resumed: false,
                                   notes: notes + [Self.localIndexNote])
        case .unknown(let detail):
            var record = attempting
            record.state = .unknown
            record.serverReply = detail
            record.updatedAt = now()
            var notes = ["The send state is UNKNOWN (\(detail)). The tool is NOT retrying, and a later send_draft for this draft is refused until you \(DirectTransportCLI.forgetInstruction(for: messageID)). Nothing here establishes whether the server took the message: look in the recipients' mail or the sent mailbox before deciding."]
            do {
                try records.put(record)
            } catch {
                notes.append("The record of sent drafts could not be updated (\(error)); it still says the send is in progress, which later calls also read as unknown.")
            }
            return SendDraftResult(outcome: .unknown, messageID: messageID, serverReply: nil,
                                   sentCopy: .notAttempted, draftRemoval: .notAttempted, resumed: false,
                                   notes: notes + [Self.localIndexNote])
        }
    }

    /// A draft chosen by its local row is gone from the server, and its entry says
    /// only the removal is pending: the removal happened after all (its reply or
    /// the write after it was lost). Records it as done.
    private func removalAlreadyHappened(_ messageID: String) throws -> SendDraftResult? {
        guard var entry = try records.entry(for: messageID), entry.effectiveState == .submitted,
              DirectTransportConfig.equalIgnoringASCIICase(entry.accountID, account.accountID),
              entry.sentCopy != .pending, entry.draftRemoval == .pending else { return nil }
        entry.draftRemoval = .done
        entry.updatedAt = now()
        var notes = ["The draft is no longer in the drafts mailbox, so its removal is recorded as done. The message was not submitted again."]
        save(entry, &notes)
        return SendDraftResult(outcome: .submitted, messageID: messageID, serverReply: entry.serverReply,
                               sentCopy: Self.stage(entry.sentCopy), draftRemoval: .done, resumed: true,
                               notes: notes + [Self.localIndexNote])
    }

    /// The stages after a submission, in order; a failed stage stays pending and
    /// the ones after it are not attempted.
    private func finishStages(_ start: SendRecord, draft: FetchedDraft, draftsBox: String,
                              resumed: Bool, notes start2: [String]) async throws -> SendDraftResult {
        var record = start
        var notes = start2
        if record.sentCopy == .pending {
            do {
                let sentBox = try await session.sentMailbox()
                // A copy stored by an earlier attempt whose reply was lost is not stored twice.
                if try await session.sentCopyExists(messageID: record.messageID, in: sentBox) {
                    notes.append("A message with this Message-ID was already in the sent mailbox, so no second copy was stored.")
                } else {
                    try await session.appendSentCopy(draft.message, to: sentBox)
                }
                record.sentCopy = .done
            } catch {
                notes.append("The sent copy could not be stored (\(error)); call send_draft again for this draft to store it. The message will not be submitted again.")
            }
            record.updatedAt = now()
            save(record, &notes)
        }
        if record.sentCopy != .pending && record.draftRemoval == .pending {
            if await session.canExpungeOneMessage() {
                do {
                    try await session.removeDraft(draft, in: draftsBox)
                    record.draftRemoval = .done
                } catch {
                    notes.append("The draft could not be removed from the drafts mailbox (\(error)); call send_draft again for this draft to remove it. The message will not be submitted again.")
                }
            } else {
                notes.append("The server cannot expunge one message by its UID, so the draft was left in the drafts mailbox rather than expunging other messages. Delete it in Mail; the message will not be submitted again.")
            }
            record.updatedAt = now()
            save(record, &notes)
        }
        notes.append(Self.localIndexNote)
        return SendDraftResult(outcome: .submitted, messageID: record.messageID, serverReply: record.serverReply,
                               sentCopy: Self.stage(record.sentCopy), draftRemoval: Self.stage(record.draftRemoval),
                               resumed: resumed, notes: notes)
    }

    /// A stage write that fails is reported, never thrown: the outcome is already known.
    private func save(_ record: SendRecord, _ notes: inout [String]) {
        do {
            try records.put(record)
        } catch {
            notes.append("The record of sent drafts could not be updated (\(error)); it may report a stage that is done as pending, and a later call then repeats only that stage. The message will not be submitted again.")
        }
    }

    private static func stage(_ stage: SendRecord.Stage) -> SendDraftResult.StageResult {
        switch stage {
        case .done: return .done
        case .pending: return .pending
        case .skipped: return .skipped
        }
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
