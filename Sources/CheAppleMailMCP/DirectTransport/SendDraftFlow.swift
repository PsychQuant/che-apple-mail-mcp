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
    func fetchDraft(uid: UInt32, in mailbox: String) async throws -> FetchedDraft
    /// Never throws: every failure is classified into the outcome.
    func submit(_ message: Data, from sender: String, to recipients: [String]) async -> SubmitOutcome
    func appendSentCopy(_ message: Data, to mailbox: String) async throws
    /// Whether the server can expunge one message by its UID (UIDPLUS).
    func canExpungeOneMessage() async -> Bool
    /// Marks the one message deleted and expunges that message only.
    func removeDraft(uid: UInt32, in mailbox: String) async throws
    func close() async
}

struct DraftSummary: Equatable, Sendable {
    let uid: UInt32
    let subject: String
    let messageID: String?
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
    /// A recipient field holds text that is not an address.
    let hasInvalidRecipient: Bool
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

    func run(_ selector: DraftSelector) async throws -> SendDraftResult {
        let draftsBox = try await session.draftsMailbox()
        let draft = try await selectDraft(selector, in: draftsBox)

        // Check 1: a Message-ID is the key of the record of sent drafts.
        guard let messageID = draft.messageID, !messageID.isEmpty else {
            throw SendDraftRefusal(description: "the draft has no Message-ID, so a second submission could not be prevented; nothing was submitted")
        }
        // Check 2: the record.
        if let existing = try records.entry(for: messageID) {
            switch existing.effectiveState {
            case .unknown, .attempting:
                throw SendDraftRefusal(description: "an earlier submission of this draft ended with its state UNKNOWN; the tool is NOT retrying. Check the recipients' mail or the sent mailbox, then clear the entry with `--direct-transport-forget \(messageID)` if it was not sent")
            case .submitted:
                if existing.sentCopy == .pending || existing.draftRemoval == .pending {
                    return try await finishStages(existing, draft: draft, draftsBox: draftsBox, resumed: true)
                }
                throw SendDraftRefusal(description: "this draft was already submitted at \(Self.iso(existing.updatedAt)); nothing was submitted")
            }
        }
        // Check 3: the sender.
        guard draft.from.count == 1, let sender = draft.from.first, account.mayUseFrom(sender) else {
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

        let attempting = SendRecord(messageID: messageID, accountID: account.accountID, state: .attempting,
                                    sentCopy: account.sentCopy == .append ? .pending : .skipped,
                                    draftRemoval: .pending, updatedAt: now(), serverReply: nil)
        if try records.claim(attempting) != nil {
            throw SendDraftRefusal(description: "another call is submitting this draft or has submitted it; nothing was submitted")
        }

        switch await session.submit(outgoing, from: sender, to: draft.recipients) {
        case .accepted(let reply):
            var record = attempting
            record.state = .submitted
            record.serverReply = reply
            record.updatedAt = now()
            try records.put(record)
            return try await finishStages(record, draft: draft, draftsBox: draftsBox, resumed: false)
        case .notAccepted(let reply):
            try records.remove(messageID)
            return SendDraftResult(outcome: .notSent, messageID: messageID, serverReply: reply,
                                   sentCopy: .notAttempted, draftRemoval: .notAttempted, resumed: false,
                                   notes: ["The server did not accept the message. The draft is still in the drafts mailbox."])
        case .unknown(let detail):
            var record = attempting
            record.state = .unknown
            record.serverReply = detail
            record.updatedAt = now()
            try records.put(record)
            return SendDraftResult(outcome: .unknown, messageID: messageID, serverReply: nil,
                                   sentCopy: .notAttempted, draftRemoval: .notAttempted, resumed: false,
                                   notes: ["The send state is UNKNOWN (\(detail)). The tool is NOT retrying, and a later send_draft for this draft is refused until the entry is cleared with `--direct-transport-forget \(messageID)`. Nothing here establishes whether the server took the message: look in the recipients' mail or the sent mailbox before deciding."])
        }
    }

    private func selectDraft(_ selector: DraftSelector, in mailbox: String) async throws -> FetchedDraft {
        let candidates: [DraftSummary]
        switch selector {
        case .localRow(let row):
            guard let id = try localMessageID(row), !id.isEmpty else {
                throw SendDraftRefusal(description: "the local message \(row) has no Message-ID to find it on the server by; nothing was submitted")
            }
            candidates = try await session.drafts(withMessageID: id, in: mailbox).filter { $0.messageID == id }
        case .subject(let subject):
            candidates = try await session.drafts(withSubjectContaining: subject, in: mailbox).filter { $0.subject == subject }
        }
        guard candidates.count == 1, let only = candidates.first else {
            throw SendDraftRefusal(description: candidates.isEmpty
                ? "no draft in the server's drafts mailbox matched; a draft that exists only on this Mac (not yet synchronised) cannot be sent this way. Nothing was submitted"
                : "\(candidates.count) drafts in the server's drafts mailbox matched; nothing was submitted")
        }
        return try await session.fetchDraft(uid: only.uid, in: mailbox)
    }

    /// The stages after a submission, in order; a failed stage stays pending and
    /// the ones after it are not attempted.
    private func finishStages(_ start: SendRecord, draft: FetchedDraft, draftsBox: String,
                              resumed: Bool) async throws -> SendDraftResult {
        var record = start
        var notes: [String] = []
        if record.sentCopy == .pending {
            do {
                try await session.appendSentCopy(draft.message, to: try await session.sentMailbox())
                record.sentCopy = .done
            } catch {
                notes.append("The sent copy could not be stored (\(error)); call send_draft again for this draft to store it. The message will not be submitted again.")
            }
            record.updatedAt = now()
            try records.put(record)
        }
        var removal: SendDraftResult.StageResult = record.draftRemoval == .done ? .done : .pending
        if record.sentCopy != .pending && record.draftRemoval == .pending {
            if await session.canExpungeOneMessage() {
                do {
                    try await session.removeDraft(uid: draft.uid, in: draftsBox)
                    record.draftRemoval = .done
                    removal = .done
                } catch {
                    notes.append("The draft could not be removed from the drafts mailbox (\(error)); call send_draft again for this draft to remove it. The message will not be submitted again.")
                }
            } else {
                notes.append("The server cannot expunge one message by its UID, so the draft was left in the drafts mailbox rather than expunging other messages. Delete it in Mail; the message will not be submitted again.")
            }
            record.updatedAt = now()
            try records.put(record)
        }
        notes.append("This tool does not change the local mail index; Mail shows the change when it next synchronises.")
        return SendDraftResult(outcome: .submitted, messageID: record.messageID, serverReply: record.serverReply,
                               sentCopy: SendDraftResult.StageResult(rawValue: record.sentCopy.rawValue) ?? .pending,
                               draftRemoval: removal, resumed: resumed, notes: notes)
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
