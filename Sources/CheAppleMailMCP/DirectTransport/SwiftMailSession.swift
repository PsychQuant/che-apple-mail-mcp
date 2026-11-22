import Foundation
import SwiftMail

/// `DirectTransportSession` over SwiftMail (#742). The IMAP connection is opened
/// and logged in by `open`; the SMTP connection only by `prepareSubmission`, so
/// a call that completes pending stages never needs the SMTP server.
///
/// Every text this type hands out (errors, server replies) passes through
/// `redact`, which removes the password and the encodings a login sends it in:
/// a server that has received the password could echo it back.
///
/// Not covered by the unit tests beyond its pure helpers: this file is
/// exercised only against a real server (task 5 of the change).
final class SwiftMailSession: DirectTransportSession, @unchecked Sendable {
    private let account: DirectTransportConfig.Account
    private let password: String
    private let imap: IMAPServer
    private var smtp: SMTPServer?
    private let lookupLock = NSLock()
    /// Where each mailbox this session looked up came from (#748).
    private var lookupNotes: [String] = []

    private init(account: DirectTransportConfig.Account, password: String, imap: IMAPServer) {
        self.account = account
        self.password = password
        self.imap = imap
    }

    /// An error whose text has been redacted.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Connects and logs in to the IMAP server.
    static func open(account: DirectTransportConfig.Account, password: String) async throws -> SwiftMailSession {
        let imap = IMAPServer(host: account.imap.host, port: account.imap.port,
                              transportSecurity: transportSecurity(forPort: account.imap.port),
                              certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12)
        do {
            try await imap.connect()
            try await imap.login(username: account.address, password: password)
        } catch {
            try? await imap.disconnect()
            throw Failure(description: "could not log in to the IMAP server \(account.imap.host):\(account.imap.port) (\(clip(redact(describe(error), password: password, username: account.address)))); nothing was submitted")
        }
        return SwiftMailSession(account: account, password: password, imap: imap)
    }

    /// Implicit TLS on the two ports that use it (465 SMTPS, 993 IMAPS); required
    /// STARTTLS on every other port, which fails when the server does not offer it.
    /// Never `.automatic` or `.plainText`: the password must not cross an
    /// unencrypted connection.
    static func transportSecurity(forPort port: Int) -> MailTransportSecurity {
        port == 465 || port == 993 ? .implicitTLS : .startTLS
    }

    /// A Message-ID in the form the server's envelope reports (`<local@domain>`),
    /// so a value read from the local .emlx, or typed by a person, compares equal
    /// to it. Nil when it has no `@`.
    static func canonicalMessageID(_ raw: String) -> String? {
        MessageID(raw)?.description
    }

    /// `text` with the password removed, in every form a login sends it: as is,
    /// as an IMAP quoted string (`\` and `"` escaped), and base64-encoded for AUTH
    /// LOGIN and for AUTH PLAIN with an empty or the user's authorization identity.
    /// Applied to the whole text before it is cut to length, so a password that
    /// straddles the cut cannot survive as a prefix.
    static func redact(_ text: String, password: String, username: String) -> String {
        guard !password.isEmpty else { return text }
        // Longest first, so a form that contains another is removed whole.
        return passwordForms(password: password, username: username).sorted { $0.count > $1.count }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: redactionMarker) }
    }

    /// What replaces the password. `--direct-transport-set-credential` refuses a
    /// password that occurs in it, so the marker never reproduces one.
    static let redactionMarker = "[redacted]"

    static func passwordForms(password: String, username: String) -> [String] {
        let quoted = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return [password, quoted,
                Data(password.utf8).base64EncodedString(),
                Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString(),
                Data("\(username)\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()]
    }

    private func redact(_ text: String) -> String {
        Self.redact(text, password: password, username: account.address)
    }

    /// Whether `text` holds the password in any of the forms `redact` removes.
    static func containsPassword(_ text: String, password: String, username: String) -> Bool {
        guard !password.isEmpty else { return false }
        return passwordForms(password: password, username: username).contains { text.contains($0) }
    }

    private func containsPassword(_ text: String) -> Bool {
        Self.containsPassword(text, password: password, username: account.address)
    }

    /// At most 300 characters. Only ever applied after `redact`.
    static func clip(_ text: String) -> String { String(text.prefix(300)) }

    /// Runs `body`, handing out any error as a redacted `Failure`.
    private func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let refusal as SendDraftRefusal {
            throw refusal
        } catch {
            throw Failure(description: Self.clip(redact(Self.describe(error))))
        }
    }

    func draftsMailbox() async throws -> String {
        try await lookUp(.drafts, attribute: .drafts, declared: account.draftsMailbox)
    }

    func sentMailbox() async throws -> String {
        try await lookUp(.sent, attribute: .sent, declared: account.sentMailbox)
    }

    func mailboxLookupNotes() async -> [String] { recordedLookupNotes() }

    private func recordedLookupNotes() -> [String] {
        lookupLock.lock()
        defer { lookupLock.unlock() }
        return lookupNotes
    }

    private func recordLookup(_ note: String) {
        lookupLock.lock()
        defer { lookupLock.unlock() }
        lookupNotes.append(note)
    }

    /// The decision is `MailboxLookup.resolve`'s (#748). This only supplies what
    /// the server said. `listSpecialUseMailboxes` is reached only through the
    /// closure, which `resolve` calls only when the capabilities just fetched
    /// hold SPECIAL-USE: without that capability SwiftMail guesses from names.
    private func lookUp(_ role: MailboxLookup.Role, attribute: Mailbox.Info.Attributes,
                        declared: String?) async throws -> String {
        let listed = try await guarded { try await imap.listMailboxes() }
        let imap = self.imap
        let found = try await MailboxLookup.resolve(
            role, listed: listed.map(Self.listed),
            markedInList: listed.filter { $0.attributes.contains(attribute) }.map(Self.listed),
            declared: declared,
            advertisesSpecialUse: {
                // Fetched after login: the capabilities a server gives before
                // login can differ. `fetchCapabilities` also updates the set
                // SwiftMail's special-use listing reads, so the two agree.
                try await self.guarded { try await imap.fetchCapabilities() }.contains { Self.isSpecialUse($0.name) }
            },
            markedOnRequest: {
                try await self.guarded { try await imap.listSpecialUseMailboxes() }
                    .filter { $0.attributes.contains(attribute) }.map(Self.listed)
            })
        recordLookup(found.note)
        return found.name
    }

    private static func listed(_ info: Mailbox.Info) -> MailboxLookup.Listed {
        MailboxLookup.Listed(name: info.name, selectable: !info.attributes.contains(.noSelect))
    }

    /// Whether a capability's text is SPECIAL-USE (RFC 6154). Capability names
    /// are case-insensitive.
    static func isSpecialUse(_ capability: String) -> Bool {
        DirectTransportConfig.equalIgnoringASCIICase(capability, "SPECIAL-USE")
    }

    func drafts(withMessageID messageID: String, in mailbox: String) async throws -> [DraftSummary] {
        try await summaries(matching: [.header("Message-ID", Self.searchTerm(for: messageID))], in: mailbox)
    }

    /// The Message-ID without its angle brackets: header search is a substring
    /// search, and a header written without brackets would not hold them.
    /// Hits are then compared in full.
    static func searchTerm(for messageID: String) -> String {
        var term = Substring(messageID)
        if term.hasPrefix("<") { term = term.dropFirst() }
        if term.hasSuffix(">") { term = term.dropLast() }
        return String(term)
    }

    func drafts(withSubjectContaining subject: String, in mailbox: String) async throws -> [DraftSummary] {
        try await summaries(matching: [.subject(subject)], in: mailbox)
    }

    private func summaries(matching criteria: [SearchCriteria], in mailbox: String) async throws -> [DraftSummary] {
        try await guarded {
            let selection = try await imap.selectMailbox(mailbox)
            let found: MessageIdentifierSet<UID> = try await imap.search(criteria: criteria)
            var result: [DraftSummary] = []
            for uid in found.toArray() {
                // A hit whose envelope cannot be read might be the second match:
                // dropping it would make one match look unique.
                guard let info = try await imap.fetchMessageInfo(for: uid) else {
                    throw SendDraftRefusal(description: "the server found a draft whose envelope it then did not return, so the match cannot be shown to be unique; nothing was submitted")
                }
                result.append(DraftSummary(uid: uid.value, subject: info.subject ?? "",
                                           messageID: info.messageId?.description,
                                           uidValidity: selection.uidValidity.value))
            }
            return result
        }
    }

    /// Selects `mailbox` and throws unless its UIDVALIDITY is still `expected`.
    private func select(_ mailbox: String, expecting expected: UInt32) async throws {
        let selection = try await imap.selectMailbox(mailbox)
        guard selection.uidValidity.value == expected else {
            throw SendDraftRefusal(description: "the drafts mailbox changed its UIDVALIDITY while it was in use, so the draft's UID may name another message; nothing more was done")
        }
    }

    func fetchDraft(_ summary: DraftSummary, in mailbox: String) async throws -> FetchedDraft {
        try await guarded {
            try await select(mailbox, expecting: summary.uidValidity)
            let id = UID(summary.uid)
            let message = try await imap.fetchRawMessage(identifier: id)
            guard let info = try await imap.fetchMessageInfo(for: id) else {
                throw SendDraftRefusal(description: "the server returned no envelope for the draft; nothing was submitted")
            }
            // A header this reader cannot parse is refused at check 5 (Bcc removal
            // reads it the same way); until then, nothing here is decided from it.
            let fields = try? BccRemoval.fields(in: message)
            if let fields {
                // The Message-ID the record is keyed by must be the one in the bytes submitted.
                let headerIDs = fields.filter { $0.name == "message-id" }.map(\.value)
                guard headerIDs.count == 1, let headerID = Self.canonicalMessageID(headerIDs[0]),
                      SendDraftFlow.same(headerID, info.messageId?.description) else {
                    throw SendDraftRefusal(description: "the draft's Message-ID header is missing, repeated, or not the one the server's envelope reports; nothing was submitted")
                }
            }
            let invalid: (AddressListEntry) -> Bool = { if case .invalid = $0 { return true } else { return false } }
            let recipientEntries = info.toAddresses + info.ccAddresses + info.bccAddresses
            let agreement = fields.map { fields in Self.addressFieldsAgree(
                fields: fields, from: info.fromAddresses.mailboxes.count, to: info.toAddresses.mailboxes.count,
                cc: info.ccAddresses.mailboxes.count, bcc: info.bccAddresses.mailboxes.count) } ?? (sender: true, recipients: true)
            let draft = FetchedDraft(uid: summary.uid, message: message, messageID: info.messageId?.description,
                                     subject: info.subject ?? "",
                                     from: info.fromAddresses.mailboxes.map(\.address),
                                     recipients: recipientEntries.mailboxes.map(\.address),
                                     hasInvalidRecipient: recipientEntries.contains(where: invalid) || !agreement.recipients,
                                     hasInvalidSender: info.fromAddresses.contains(where: invalid) || !agreement.sender,
                                     uidValidity: summary.uidValidity)
            // A server that has the password could put it in what it reports; none
            // of that text reaches a result or the record.
            let reported = [draft.messageID ?? "", draft.subject] + draft.from + draft.recipients
            guard !reported.contains(where: containsPassword) else {
                throw SendDraftRefusal(description: "the draft's header holds the account password; nothing was submitted")
            }
            return draft
        }
    }

    /// Whether the header's address fields agree with the server's envelope.
    /// From, To, Cc and Bcc may each appear at most once (RFC 5322 section 3.6),
    /// From exactly once; and each field must name as many addresses as the
    /// envelope reports for it. A difference means the server left out text it
    /// could not parse, which the checks would otherwise not see.
    static func addressFieldsAgree(fields: [(name: String, value: String)], from: Int, to: Int, cc: Int, bcc: Int)
        -> (sender: Bool, recipients: Bool) {
        func agrees(_ name: String, _ envelope: Int, required: Bool) -> Bool {
            let values = fields.filter { $0.name == name }.map(\.value)
            if values.isEmpty { return !required && envelope == 0 }
            guard values.count == 1 else { return false }
            // Blank is an empty list; otherwise it must read plainly as addresses
            // (an empty group such as `undisclosed-recipients:;` counts 0).
            if values[0].trimmingCharacters(in: .whitespaces).isEmpty { return !required && envelope == 0 }
            guard let count = BccRemoval.addressList(inFieldValue: values[0]) else { return false }
            if count == 0 { return !required && envelope == 0 }
            return count == envelope
        }
        return (agrees("from", from, required: true),
                agrees("to", to, required: false) && agrees("cc", cc, required: false) && agrees("bcc", bcc, required: false))
    }

    func sentCopyExists(messageID: String, in mailbox: String) async throws -> Bool {
        try await guarded {
            try await imap.selectMailbox(mailbox)
            // SEARCH HEADER is a substring search: each hit's own Message-ID must equal it.
            let found: MessageIdentifierSet<UID> = try await imap.search(criteria: [.header("Message-ID", Self.searchTerm(for: messageID))])
            for uid in found.toArray() {
                guard let info = try await imap.fetchMessageInfo(for: uid) else {
                    throw Failure(description: "the server found a message in the sent mailbox whose envelope it then did not return")
                }
                if SendDraftFlow.same(info.messageId?.description, messageID) { return true }
            }
            return false
        }
    }

    func prepareSubmission() async throws {
        let server = SMTPServer(host: account.smtp.host, port: account.smtp.port,
                                transportSecurity: Self.transportSecurity(forPort: account.smtp.port),
                                certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12)
        do {
            try await server.connect()
            try await server.login(username: account.address, password: password)
        } catch {
            try? await server.disconnect()
            throw Failure(description: "could not log in to the SMTP server \(account.smtp.host):\(account.smtp.port) (\(Self.clip(redact(Self.describe(error)))))")
        }
        smtp = server
    }

    func submit(_ message: Data, from sender: String, to recipients: [String]) async -> SubmitOutcome {
        guard let smtp else { return .notAccepted(reply: nil) }
        let outcome: SubmitOutcome
        do {
            let result = try await smtp.sendRawMessage(message, from: EmailAddress(address: sender),
                                                       to: recipients.map { EmailAddress(address: $0) })
            outcome = Self.classify(.success(result))
        } catch {
            outcome = Self.classify(.failure(error))
        }
        switch outcome {
        case .accepted(let reply): return .accepted(reply: Self.clip(redact(reply)))
        case .notAccepted(let reply): return .notAccepted(reply: reply.map { Self.clip(redact($0)) })
        case .unknown(let detail): return .unknown(detail: Self.clip(redact(detail)))
        }
    }

    func appendSentCopy(_ message: Data, to mailbox: String) async throws {
        try await guarded {
            try await imap.append(rawMessage: message, to: mailbox, flags: [.seen], internalDate: Date())
        }
    }

    func appendDraft(_ message: Data, to mailbox: String) async -> AppendOutcome {
        let result: Result<AppendResult, Error>
        do {
            result = .success(try await imap.append(rawMessage: message, to: mailbox, flags: [.draft, .seen],
                                                    internalDate: Date()))
        } catch {
            result = .failure(error)
        }
        switch Self.classifyAppend(result) {
        case .appended(let uid, let uidValidity): return .appended(uid: uid, uidValidity: uidValidity)
        case .notAppended(let detail): return .notAppended(detail: Self.clip(redact(detail)))
        case .unknown(let detail): return .unknown(detail: Self.clip(redact(detail)))
        }
    }

    /// Maps what SwiftMail reports for one APPEND to the three outcomes (#744).
    /// In the pinned revision a failed command is never resent
    /// (`IMAPConnection+CommandExecution.swift`, `runCommandHandler` rethrows).
    /// `commandFailed` reaches an `append` call only from the tagged NO or BAD
    /// reply to the APPEND (`AppendHandler`) or from re-authenticating before the
    /// command is sent (`IMAPServer.executeCommand`), and `appendLimitExceeded` is
    /// raised before anything is sent: in each case the draft was not stored. A
    /// closed connection, a timeout and every error this code does not recognise
    /// are `unknown`. Re-read those three files before moving the pin.
    static func classifyAppend(_ result: Result<AppendResult, Error>) -> AppendOutcome {
        switch result {
        case .success(let stored):
            return .appended(uid: stored.firstUID?.value, uidValidity: stored.uidValidity?.value)
        case .failure(let error):
            if let failure = error as? IMAPError {
                switch failure {
                case .commandFailed, .appendLimitExceeded: return .notAppended(detail: describe(failure))
                default: return .unknown(detail: describe(failure))
                }
            }
            return .unknown(detail: describe(error))
        }
    }

    func canExpungeOneMessage() async -> Bool { await imap.supportsUIDPlus }

    func removeDraft(_ draft: FetchedDraft, in mailbox: String) async throws {
        try await guarded {
            try await select(mailbox, expecting: draft.uidValidity)
            let one = UIDSet(UID(draft.uid))
            try await imap.store(flags: [.deleted], on: one, operation: .add)
            try await imap.expunge(messages: one)
        }
    }

    func close() async {
        try? await smtp?.disconnect()
        try? await imap.disconnect()
    }

    /// Maps what SwiftMail reports for one submission to the three outcomes.
    /// Only the cases SwiftMail documents as provably not accepted become
    /// `notAccepted`; everything else, including errors this code does not
    /// recognise, is `unknown`.
    static func classify(_ result: Result<SMTPSendResult, Error>) -> SubmitOutcome {
        switch result {
        case .success(let sent):
            return .accepted(reply: "\(sent.response.code) \(sent.response.message)")
        case .failure(let error):
            if let failure = error as? SMTPSendError {
                let reply = failure.response.map { "\($0.code) \($0.message)" }
                switch failure.acceptance {
                case .notAccepted, .rejectedTransiently, .rejectedPermanently:
                    return .notAccepted(reply: reply)
                case .ambiguous:
                    return .unknown(detail: describe(failure))
                @unknown default:
                    return .unknown(detail: describe(failure))
                }
            }
            // SwiftMail throws SMTPError only before the mail transaction starts:
            // in the pinned revision every failure from MAIL FROM onward goes
            // through abortSubmission, which returns an SMTPSendError
            // (SMTPServer+Send.swift, performSubmission). Re-read that path
            // before moving the pin.
            if error is SMTPError { return .notAccepted(reply: nil) }
            return .unknown(detail: describe(error))
        }
    }

    /// An error's whole text on one line. Not a redaction and not cut: callers
    /// that hand it out pass it through `redact` and then `clip`.
    private static func describe(_ error: Error) -> String {
        String(describing: error).replacingOccurrences(of: "\n", with: " ")
    }
}
