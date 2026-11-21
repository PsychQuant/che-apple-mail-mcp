import Foundation
import MCP

/// What the server did with one APPEND (#744).
enum AppendOutcome: Equatable, Sendable {
    /// The server completed the command. The UID is present when it reports one (UIDPLUS).
    case appended(uid: UInt32?, uidValidity: UInt32?)
    /// Provably not stored: the server refused the command, or it was never sent.
    case notAppended(detail: String)
    /// Everything else.
    case unknown(detail: String)
}

/// The result of one `append_draft` call that reached the server.
struct AppendDraftResult: Equatable {
    enum Outcome: String { case appended, notAppended = "not_appended", unknown }

    let outcome: Outcome
    let messageID: String
    let mailbox: String
    let uid: UInt32?
    let uidValidity: UInt32?
    let notes: [String]
}

/// The steps of `append_draft` once the message is built: find the drafts
/// mailbox, append once, and after an outcome that could not be established,
/// look once for the message.
struct AppendDraftFlow {
    let session: DirectTransportSession

    func run(_ built: DraftMessage.Built) async throws -> AppendDraftResult {
        let mailbox = try await session.draftsMailbox()
        func result(_ outcome: AppendDraftResult.Outcome, uid: UInt32? = nil, uidValidity: UInt32? = nil,
                    _ notes: [String]) -> AppendDraftResult {
            AppendDraftResult(outcome: outcome, messageID: built.messageID, mailbox: mailbox, uid: uid,
                              uidValidity: uidValidity, notes: notes)
        }
        switch await session.appendDraft(built.mime, to: mailbox) {
        case .appended(let uid, let uidValidity):
            return result(.appended, uid: uid, uidValidity: uidValidity, [SendDraftFlow.localIndexNote])
        case .notAppended(let detail):
            return result(.notAppended, ["The server did not store the draft: \(detail)"])
        case .unknown(let detail):
            // One look, never a second APPEND. Only a hit is evidence
            // (`timeout-outcome-boundary.md`): the search can fail, and a server
            // may not show a message it has just stored.
            let hits = (try? await session.drafts(withMessageID: built.messageID, in: mailbox))?
                .filter { SendDraftFlow.same($0.messageID, built.messageID) } ?? []
            if hits.count == 1, let only = hits.first {
                return result(.appended, uid: only.uid, uidValidity: only.uidValidity, [
                    "The server's reply to the APPEND was not received (\(detail)); a search then found it in the drafts mailbox.",
                    SendDraftFlow.localIndexNote,
                ])
            }
            if hits.count > 1 {
                return result(.appended, [
                    "The server's reply to the APPEND was not received (\(detail)); a search then found it in the drafts mailbox, \(hits.count) times under this Message-ID, so no UID is reported.",
                    SendDraftFlow.localIndexNote,
                ])
            }
            return result(.unknown, [
                "Whether the server stored the draft could not be established (\(detail)).",
                "A search of the drafts mailbox did not show it; that is not evidence that it was not stored.",
                "This tool is not retrying. A second call would create a second draft if the first was stored: look in the drafts mailbox for \(built.messageID) before calling again.",
            ])
        }
    }
}

/// The `append_draft` tool (#744): argument checks, the message, the
/// configuration and the credential, then `AppendDraftFlow`. Everything outside
/// the process comes in through `Environment`.
enum AppendDraftTool {
    static let name = "append_draft"
    static let argumentNames: Set<String> = ["account_name", "account_id", "to", "cc", "bcc", "subject", "body", "from_name"]

    /// Kept here so the test of the caveats reads the same text the server lists.
    static let description = "Create a new plain-text draft in the server's drafts mailbox over IMAP, without Mail (#744, #729). NOT YET RUN AGAINST A REAL MAIL SERVER: until the result is recorded on issue #744, treat every outcome as unverified, including whether Mail and other clients show the result as an editable draft. Only for accounts listed in the server's direct-transport.json, with a password stored by running the binary with --direct-transport-set-credential <address>; any other account is refused and no Mail path is used instead. Takes account_name or account_id, to, cc and bcc (lists of bare addresses, at least one recipient in all; display names are refused), subject (not empty), body (plain text) and optionally from_name (the sender's display name; the sender's address is always the account's). It accepts no attachment, format, reply or signature argument. The tool builds the whole message itself: one text/plain part in UTF-8 with a new Message-ID, not the layout Mail gives its own drafts, so that send_draft can submit it as stored. Bcc recipients are kept in the draft's Bcc field. outcome is appended (the server completed the command, or a search afterwards found the message; uid is given when the server reports one), not_appended (the server refused, or nothing was sent), or unknown: whether the server stored the draft could not be established, and the tool is NOT retrying. A second call always creates a second draft, so after unknown look in the drafts mailbox for the message_id first. The result carries message_id, which send_draft accepts to send this draft. Mail's local index is not changed and shows the draft when Mail next syncs."

    struct Environment {
        let stateDirectory: URL
        let password: (String) throws -> String?
        let openSession: (DirectTransportConfig.Account, String) async throws -> DirectTransportSession
        let now: () -> Date
        let newID: () -> UUID
    }

    static func run(_ arguments: [String: Value], _ environment: Environment) async throws -> String {
        if let extra = arguments.keys.sorted().first(where: { !argumentNames.contains($0) }) {
            throw MailError.invalidParameter("append_draft does not accept '\(extra)'; it takes only account_name, account_id, to, cc, bcc, subject, body and from_name")
        }
        let accountName = try string(arguments, "account_name")
        let accountID = try string(arguments, "account_id")
        let fromName = try string(arguments, "from_name")
        let to = try strings(arguments, "to")
        let cc = try strings(arguments, "cc")
        let bcc = try strings(arguments, "bcc")
        guard let subject = try string(arguments, "subject") else {
            throw MailError.invalidParameter("append_draft needs 'subject'")
        }
        guard let body = try string(arguments, "body") else {
            throw MailError.invalidParameter("append_draft needs 'body'")
        }
        guard (accountName?.isEmpty == false) || (accountID?.isEmpty == false) else {
            throw MailError.invalidParameter("append_draft needs account_name or account_id")
        }
        if let problem = refusal(to: to, cc: cc, bcc: bcc, subject: subject, body: body, fromName: fromName) {
            throw MailError.invalidParameter("\(problem). Nothing was appended")
        }

        let configURL = environment.stateDirectory.appendingPathComponent(DirectTransportConfig.fileName)
        let config: DirectTransportConfig
        do {
            guard let loaded = try DirectTransportConfig.load(from: configURL) else {
                throw MailError.operationFailed("direct transport is not configured: no \(DirectTransportConfig.fileName) in the server's state directory. Nothing was appended, and no Mail path is used instead")
            }
            config = loaded
        } catch let problem as DirectTransportConfig.Problem {
            throw MailError.operationFailed("\(problem). Nothing was appended")
        }
        if let id = accountID, !id.isEmpty, let name = accountName, !name.isEmpty,
           let byID = config.account(accountID: id, accountName: nil),
           let byName = config.account(accountID: nil, accountName: name), byName != byID {
            throw MailError.invalidParameter("account_id and account_name name different accounts (\(byID.address) and \(name)); give one of them")
        }
        guard let account = config.account(accountID: accountID, accountName: accountName) else {
            throw MailError.operationFailed("direct transport is not configured for \(accountID ?? accountName ?? "this account"). Nothing was appended, and no Mail path is used instead")
        }

        let built = DraftMessage.build(fromName: fromName?.isEmpty == true ? nil : fromName, fromAddress: account.address,
                                       to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                                       date: environment.now(), messageIDLocalPart: environment.newID())
        let records = SendRecordStore(directory: environment.stateDirectory)
        do {
            // The lock `send_draft` holds: one direct-transport call at a time.
            return try await records.withSubmissionLock {
                try await runHoldingTheLock(built, account: account, environment)
            }
        } catch is SendRecordStore.Busy {
            throw MailError.operationFailed("another send_draft or append_draft call is running; nothing was appended. Try again when it has finished")
        }
    }

    private static func runHoldingTheLock(_ built: DraftMessage.Built, account: DirectTransportConfig.Account,
                                          _ environment: Environment) async throws -> String {
        let password: String
        do {
            guard let stored = try environment.password(account.address) else {
                throw MailError.operationFailed("no stored credential for \(account.address): run the server binary with `--direct-transport-set-credential \(DirectTransportCLI.shellQuoted(account.address))` and type the app-specific password. Nothing was appended")
            }
            password = stored
        } catch let failure as DirectTransportCredential.Failure {
            throw MailError.operationFailed("\(failure). Nothing was appended")
        }
        let session: DirectTransportSession
        do {
            session = try await environment.openSession(account, password)
        } catch {
            throw MailError.operationFailed("\(error)")
        }
        let result: AppendDraftResult
        do {
            result = try await AppendDraftFlow(session: session).run(built)
        } catch let refusal as SendDraftRefusal {
            await session.close()
            throw MailError.operationFailed("\(refusal.description). Nothing was appended")
        } catch {
            await session.close()
            throw MailError.operationFailed("append_draft stopped before the APPEND (\(error)); nothing was appended")
        }
        await session.close()
        return render(result)
    }

    /// Why the content cannot be made into a message; nil when it can.
    static func refusal(to: [String], cc: [String], bcc: [String], subject: String, body: String,
                        fromName: String?) -> String? {
        guard !(to.isEmpty && cc.isEmpty && bcc.isEmpty) else {
            return "append_draft needs at least one recipient in to, cc or bcc"
        }
        for (field, list) in [("to", to), ("cc", cc), ("bcc", bcc)] {
            if let bad = list.first(where: { !isBareAddress($0) }) {
                return "'\(field)' holds \(printable(bad)), which is not a bare address (name@domain in printable ASCII, at most \(DirectDraft.maxAddressOctets) octets); display names are not accepted"
            }
        }
        guard !subject.isEmpty else { return "append_draft needs a subject that is not empty" }
        if hasControlCharacter(subject) { return "'subject' holds a control character" }
        if let fromName, hasControlCharacter(fromName) { return "'from_name' holds a control character" }
        if body.unicodeScalars.contains(where: { $0.value == 0 }) { return "'body' holds a NUL character" }
        return nil
    }

    /// One `@` between non-empty parts of printable ASCII, without the
    /// characters that structure an address list or a display name.
    static func isBareAddress(_ text: String) -> Bool {
        guard text.utf8.count <= DirectDraft.maxAddressOctets, isSimpleAddrSpec(text) else { return false }
        let structural = Set(",;:<>()[]\"\\".unicodeScalars)
        guard text.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E && !structural.contains($0) }) else {
            return false
        }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    private static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A refused value as it may be shown: cut short, control characters replaced.
    private static func printable(_ text: String) -> String {
        let shown = String(String.UnicodeScalarView(text.unicodeScalars.prefix(80).map {
            ($0.value < 0x20 || $0.value == 0x7F) ? "?" : $0
        }))
        return "'\(shown)'"
    }

    static func render(_ result: AppendDraftResult) -> String {
        let object: [String: Any] = [
            "outcome": result.outcome.rawValue,
            "message_id": result.messageID,
            "mailbox": result.mailbox,
            "uid": result.uid.map { Int($0) as Any } ?? NSNull(),
            "uid_validity": result.uidValidity.map { Int($0) as Any } ?? NSNull(),
            "notes": result.notes,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A string argument, nil when absent; any other value, JSON null included, is refused by name.
    private static func string(_ arguments: [String: Value], _ key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard case .string(let text) = value else {
            throw MailError.invalidParameter("'\(key)' must be a string")
        }
        return text
    }

    /// A list-of-strings argument, empty when absent; anything else is refused by name.
    private static func strings(_ arguments: [String: Value], _ key: String) throws -> [String] {
        guard let value = arguments[key] else { return [] }
        guard case .array(let items) = value else {
            throw MailError.invalidParameter("'\(key)' must be a list of strings")
        }
        return try items.map { item in
            guard case .string(let text) = item else {
                throw MailError.invalidParameter("'\(key)' must be a list of strings")
            }
            return text
        }
    }
}
