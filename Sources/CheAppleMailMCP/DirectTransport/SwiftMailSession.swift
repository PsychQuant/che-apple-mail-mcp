import Foundation
import SwiftMail

/// `DirectTransportSession` over SwiftMail (#742): one IMAP and one SMTP
/// connection, opened and authenticated before any draft is looked at, so a
/// login failure happens before the record of sent drafts is touched.
///
/// Not covered by the unit tests, which use a stand-in: this file is exercised
/// only against a real server (task 5 of the change).
final class SwiftMailSession: DirectTransportSession, @unchecked Sendable {
    private let imap: IMAPServer
    private let smtp: SMTPServer

    private init(imap: IMAPServer, smtp: SMTPServer) {
        self.imap = imap
        self.smtp = smtp
    }

    struct OpenFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// Connects and logs in to both servers. The password is used here and not kept.
    static func open(account: DirectTransportConfig.Account, password: String) async throws -> SwiftMailSession {
        // Never `.automatic` or `.plainText`: the password must not cross an
        // unencrypted connection, so STARTTLS is required, not opportunistic, and
        // the certificate is fully verified.
        let imap = IMAPServer(host: account.imap.host, port: account.imap.port,
                              transportSecurity: Self.transportSecurity(forPort: account.imap.port),
                              certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12)
        let smtp = SMTPServer(host: account.smtp.host, port: account.smtp.port,
                              transportSecurity: Self.transportSecurity(forPort: account.smtp.port),
                              certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12)
        do {
            try await imap.connect()
            try await imap.login(username: account.address, password: password)
        } catch {
            try? await imap.disconnect()
            throw OpenFailed(description: "could not log in to the IMAP server \(account.imap.host):\(account.imap.port) (\(Self.describe(error))); nothing was submitted")
        }
        do {
            try await smtp.connect()
            try await smtp.login(username: account.address, password: password)
        } catch {
            try? await imap.disconnect()
            try? await smtp.disconnect()
            throw OpenFailed(description: "could not log in to the SMTP server \(account.smtp.host):\(account.smtp.port) (\(Self.describe(error))); nothing was submitted")
        }
        return SwiftMailSession(imap: imap, smtp: smtp)
    }

    /// Implicit TLS on the two ports that use it (465 SMTPS, 993 IMAPS); required
    /// STARTTLS on every other port, which fails when the server does not offer it.
    static func transportSecurity(forPort port: Int) -> MailTransportSecurity {
        port == 465 || port == 993 ? .implicitTLS : .startTLS
    }

    func draftsMailbox() async throws -> String { try await specialUse(.drafts, named: "\\Drafts") }
    func sentMailbox() async throws -> String { try await specialUse(.sent, named: "\\Sent") }

    /// Only the attribute the server reports counts. SwiftMail's `draftsFolder`
    /// falls back to matching folder names, which the spec does not allow.
    private func specialUse(_ attribute: Mailbox.Info.Attributes, named label: String) async throws -> String {
        let marked = try await imap.listMailboxes().filter { $0.attributes.contains(attribute) }
        guard marked.count == 1, let only = marked.first else {
            throw SendDraftRefusal(description: marked.isEmpty
                ? "the server marks no mailbox \(label); nothing was submitted"
                : "the server marks \(marked.count) mailboxes \(label); nothing was submitted")
        }
        return only.name
    }

    func drafts(withMessageID messageID: String, in mailbox: String) async throws -> [DraftSummary] {
        try await summaries(matching: [.header("Message-ID", messageID)], in: mailbox)
    }

    func drafts(withSubjectContaining subject: String, in mailbox: String) async throws -> [DraftSummary] {
        try await summaries(matching: [.subject(subject)], in: mailbox)
    }

    private func summaries(matching criteria: [SearchCriteria], in mailbox: String) async throws -> [DraftSummary] {
        try await imap.selectMailbox(mailbox)
        let found: MessageIdentifierSet<UID> = try await imap.search(criteria: criteria)
        var result: [DraftSummary] = []
        for uid in found.toArray() {
            guard let info = try await imap.fetchMessageInfo(for: uid) else { continue }
            result.append(DraftSummary(uid: uid.value, subject: info.subject ?? "", messageID: info.messageId?.description))
        }
        return result
    }

    func fetchDraft(uid: UInt32, in mailbox: String) async throws -> FetchedDraft {
        try await imap.selectMailbox(mailbox)
        let id = UID(uid)
        let message = try await imap.fetchRawMessage(identifier: id)
        guard let info = try await imap.fetchMessageInfo(for: id) else {
            throw SendDraftRefusal(description: "the server returned no envelope for the draft; nothing was submitted")
        }
        let recipientEntries = info.toAddresses + info.ccAddresses + info.bccAddresses
        let invalid = recipientEntries.contains { if case .invalid = $0 { return true } else { return false } }
            || info.fromAddresses.contains { if case .invalid = $0 { return true } else { return false } }
        return FetchedDraft(uid: uid, message: message, messageID: info.messageId?.description,
                            subject: info.subject ?? "",
                            from: info.fromAddresses.mailboxes.map(\.address),
                            recipients: recipientEntries.mailboxes.map(\.address),
                            hasInvalidRecipient: invalid)
    }

    func submit(_ message: Data, from sender: String, to recipients: [String]) async -> SubmitOutcome {
        do {
            let result = try await smtp.sendRawMessage(message, from: EmailAddress(address: sender),
                                                       to: recipients.map { EmailAddress(address: $0) })
            return Self.classify(.success(result))
        } catch {
            return Self.classify(.failure(error))
        }
    }

    func appendSentCopy(_ message: Data, to mailbox: String) async throws {
        try await imap.append(rawMessage: message, to: mailbox, flags: [.seen], internalDate: Date())
    }

    func canExpungeOneMessage() async -> Bool { await imap.supportsUIDPlus }

    func removeDraft(uid: UInt32, in mailbox: String) async throws {
        try await imap.selectMailbox(mailbox)
        let one = UIDSet(UID(uid))
        try await imap.store(flags: [.deleted], on: one, operation: .add)
        try await imap.expunge(messages: one)
    }

    func close() async {
        try? await smtp.disconnect()
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
            // SwiftMail throws SMTPError only before the mail transaction starts.
            if error is SMTPError { return .notAccepted(reply: nil) }
            return .unknown(detail: describe(error))
        }
    }

    /// An error's text for a result, without anything that could hold a password.
    private static func describe(_ error: Error) -> String {
        String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(300).description
    }
}
