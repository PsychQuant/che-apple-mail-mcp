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

/// The result of one `append_draft` call that passed its checks and tried to reach the server.
struct AppendDraftResult: Equatable {
    enum Outcome: String { case appended, notAppended = "not_appended", unknown }

    let outcome: Outcome
    let messageID: String
    /// Nil when the call stopped before the drafts mailbox was known.
    let mailbox: String?
    let uid: UInt32?
    let uidValidity: UInt32?
    let notes: [String]

    func adding(notes more: [String]) -> AppendDraftResult {
        AppendDraftResult(outcome: outcome, messageID: messageID, mailbox: mailbox, uid: uid,
                          uidValidity: uidValidity, notes: notes + more)
    }
}

/// The steps of `append_draft` once the message is built: find the drafts
/// mailbox, append once, and after an outcome that could not be established,
/// try once to find the message.
struct AppendDraftFlow {
    let session: DirectTransportSession

    static let notDeduplicatedNote = "Calls are not de-duplicated: if append_draft is called again and that call also stores its draft, there are two drafts."
    static let indexNoteAppended = "This tool does not change the local mail index; the draft can appear in Mail only after Mail synchronises the drafts mailbox."
    static let indexNoteUnknown = "This tool does not change the local mail index. Whether the draft shows in Mail, now or after Mail synchronises, does not establish whether it was stored."
    static let indexNoteNotAppended = "This tool does not change the local mail index."

    /// A failure before the APPEND command was sent: nothing was appended.
    static func notAppendedBeforeAppend(_ built: DraftMessage.Built, mailbox: String?, _ reason: String) -> AppendDraftResult {
        AppendDraftResult(outcome: .notAppended, messageID: built.messageID, mailbox: mailbox, uid: nil, uidValidity: nil,
                          notes: ["The APPEND was not sent: \(reason).", indexNoteNotAppended])
    }

    func run(_ built: DraftMessage.Built) async -> AppendDraftResult {
        let mailbox: String
        do {
            mailbox = try await session.draftsMailbox()
        } catch let refusal as SendDraftRefusal {
            return Self.notAppendedBeforeAppend(built, mailbox: nil, refusal.description)
        } catch {
            return Self.notAppendedBeforeAppend(built, mailbox: nil, "the drafts mailbox could not be found (\(error))")
        }
        func result(_ outcome: AppendDraftResult.Outcome, uid: UInt32? = nil, uidValidity: UInt32? = nil,
                    _ notes: [String]) -> AppendDraftResult {
            AppendDraftResult(outcome: outcome, messageID: built.messageID, mailbox: mailbox, uid: uid,
                              uidValidity: uidValidity, notes: notes)
        }
        switch await session.appendDraft(built.mime, to: mailbox) {
        case .appended(let uid, let uidValidity):
            return result(.appended, uid: uid, uidValidity: uidValidity, [Self.indexNoteAppended, Self.notDeduplicatedNote])
        case .notAppended(let detail):
            return result(.notAppended, ["The server did not store the draft: \(detail).", Self.indexNoteNotAppended])
        case .unknown(let detail):
            // One attempt at a search, never a second APPEND. Only a hit is
            // evidence (`timeout-outcome-boundary.md`): a search that fails says
            // nothing, and a server may not yet show a message it has stored.
            let determined = "The outcome of the APPEND could not be determined from the command (\(detail))"
            let hits: [DraftSummary]
            do {
                hits = try await session.drafts(withMessageID: built.messageID, in: mailbox)
                    .filter { SendDraftFlow.same($0.messageID, built.messageID) }
            } catch {
                return result(.unknown, [
                    "\(determined), and the search for it afterwards could not be made (\(error)).",
                    Self.unknownAdvice(built), Self.indexNoteUnknown,
                ])
            }
            if hits.count == 1, let only = hits.first {
                return result(.appended, uid: only.uid, uidValidity: only.uidValidity, [
                    "\(determined); a search afterwards found it in the drafts mailbox.",
                    Self.indexNoteAppended, Self.notDeduplicatedNote,
                ])
            }
            if hits.count > 1 {
                // The Message-ID is new to this call (a random UUID), so any hit is
                // this call's message; more than one means the server holds copies.
                return result(.appended, [
                    "\(determined); a search afterwards found it in the drafts mailbox \(hits.count) times under this Message-ID, so no UID is reported. send_draft refuses a Message-ID that matches more than one draft; look at the matches in the drafts mailbox before deciding which to keep.",
                    Self.indexNoteAppended, Self.notDeduplicatedNote,
                ])
            }
            return result(.unknown, [
                "\(determined). A search of the drafts mailbox afterwards did not show it; that is not evidence that it was not stored.",
                Self.unknownAdvice(built), Self.indexNoteUnknown,
            ])
        }
    }

    static func unknownAdvice(_ built: DraftMessage.Built) -> String {
        "This tool is not retrying. If this draft was stored and a later call also stores one, there are two: look in the drafts mailbox for \(built.messageID) on the server before calling again."
    }
}

/// The `append_draft` tool (#744): argument checks, the message, the
/// configuration and the credential, then `AppendDraftFlow`. Everything outside
/// the process comes in through `Environment`.
enum AppendDraftTool {
    static let name = "append_draft"
    static let argumentNames: Set<String> = ["account_name", "account_id", "to", "cc", "bcc", "subject", "body", "from_name"]

    /// Bounds on what a call may carry, checked before anything is built.
    static let maxBodyOctets = 5_000_000
    static let maxSubjectOctets = 2_000
    static let maxFromNameOctets = 200
    static let maxRecipients = 100

    /// Kept here so the test of the caveats reads the same text the server lists.
    static let description = "Create a new plain-text draft in the server's drafts mailbox over IMAP, without Mail (#744, #729). NOT YET RUN AGAINST A REAL MAIL SERVER: until the result is recorded on issue #744, treat every outcome as unverified, including whether Mail and other clients show the result as an editable draft. Only for accounts listed in the server's direct-transport.json, with a password stored by running the binary with --direct-transport-set-credential <address>; any other account is refused and no Mail path is used instead. Takes account_name or account_id, to, cc and bcc (lists of bare addresses, at least one recipient in all; display names are refused), subject (not empty), body (plain text) and optionally from_name (the sender's display name; the sender's address is always the account's). It accepts no attachment, format, reply or signature argument. The tool builds the whole message itself: one text/plain part in UTF-8 with a new Message-ID, not the layout Mail gives its own drafts, so that send_draft can submit it as stored. Bcc recipients are kept in the draft's Bcc field. outcome is appended (the server completed the command, or a search afterwards found the message; uid is given when the server reports one), not_appended (the server refused the command, or the call stopped before the APPEND was sent: the connection, the login or finding the drafts mailbox failed), or unknown: whether the server stored the draft could not be established, and the tool is NOT retrying. Calls are not de-duplicated: if two calls both store their drafts, there are two drafts, so after unknown look in the drafts mailbox for the message_id before calling again. The result carries message_id, which send_draft accepts to send this draft. Mail's local index is not changed and shows the draft when Mail next syncs. The drafts mailbox is the one the server marks \\Drafts (asking for its special-use mailboxes when it advertises SPECIAL-USE); for a server that marks no drafts mailbox, set drafts_mailbox in direct-transport.json to its exact name. A mailbox is never chosen by guessing from its name."

    struct Environment {
        let stateDirectory: URL
        let password: (String) throws -> String?
        let openSession: (DirectTransportConfig.Account, String) async throws -> DirectTransportSession
        let now: () -> Date
        let newID: () -> UUID
    }

    static func run(_ arguments: [String: Value], _ environment: Environment) async throws -> String {
        if let extra = arguments.keys.sorted().first(where: { !argumentNames.contains($0) }) {
            throw MailError.invalidParameter("append_draft does not accept \(printable(extra)); it takes only account_name, account_id, to, cc, bcc, subject, body and from_name")
        }
        // The recipient count is checked on the raw lists, before any element is copied.
        let listed = ["to", "cc", "bcc"].reduce(0) { total, key in
            if case .array(let items)? = arguments[key] { return total + items.count }
            return total
        }
        if listed > maxRecipients {
            throw MailError.invalidParameter("append_draft takes at most \(maxRecipients) recipients in to, cc and bcc together. Nothing was appended")
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
            throw MailError.invalidParameter("account_id and account_name name different accounts (\(byID.address) and \(printable(name))); give one of them")
        }
        guard let account = config.account(accountID: accountID, accountName: accountName) else {
            throw MailError.operationFailed("direct transport is not configured for \(printable(accountID ?? accountName ?? "this account")). Nothing was appended, and no Mail path is used instead")
        }

        let content = Content(fromName: fromName?.isEmpty == true ? nil : fromName, to: to, cc: cc, bcc: bcc,
                              subject: subject, body: body)
        let records = SendRecordStore(directory: environment.stateDirectory)
        do {
            // The lock `send_draft` holds: one direct-transport call at a time.
            return try await records.withSubmissionLock {
                try await runHoldingTheLock(content, account: account, environment)
            }
        } catch is SendRecordStore.Busy {
            throw MailError.operationFailed("another send_draft or append_draft call is running; nothing was appended. Try again when it has finished")
        }
    }

    struct Content {
        let fromName: String?
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
    }

    private static func runHoldingTheLock(_ content: Content, account: DirectTransportConfig.Account,
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
        // Built only once the call holds the lock and has a credential, so a call
        // that is refused pays nothing for a large body.
        let built = DraftMessage.build(fromName: content.fromName, fromAddress: account.address, to: content.to,
                                       cc: content.cc, bcc: content.bcc, subject: content.subject, body: content.body,
                                       date: environment.now(), messageIDLocalPart: environment.newID())
        // Every error text below is redacted again here, whatever its source did:
        // the result is the boundary the password must not cross.
        func scrubbed(_ result: AppendDraftResult) -> String {
            // The mailbox name came from the server, so it is text like any other.
            render(AppendDraftResult(
                outcome: result.outcome, messageID: result.messageID,
                mailbox: result.mailbox.map { SwiftMailSession.redact($0, password: password, username: account.address) },
                uid: result.uid,
                uidValidity: result.uidValidity,
                notes: result.notes.map { SwiftMailSession.redact($0, password: password, username: account.address) }))
        }
        let session: DirectTransportSession
        do {
            session = try await environment.openSession(account, password)
        } catch {
            // No APPEND was sent, so this is provably not appended.
            return scrubbed(AppendDraftFlow.notAppendedBeforeAppend(built, mailbox: nil, "\(error)"))
        }
        let result = await AppendDraftFlow(session: session).run(built)
        // Where the drafts mailbox came from (#748).
        let lookup = await session.mailboxLookupNotes()
        await session.close()
        return scrubbed(result.adding(notes: lookup))
    }

    /// Why the content cannot be made into a message; nil when it can.
    static func refusal(to: [String], cc: [String], bcc: [String], subject: String, body: String,
                        fromName: String?) -> String? {
        // The recipient checks come first so a long list is refused by count
        // before every element is parsed.
        guard !(to.isEmpty && cc.isEmpty && bcc.isEmpty) else {
            return "append_draft needs at least one recipient in to, cc or bcc"
        }
        guard to.count + cc.count + bcc.count <= maxRecipients else {
            return "append_draft takes at most \(maxRecipients) recipients in to, cc and bcc together"
        }
        for (field, list) in [("to", to), ("cc", cc), ("bcc", bcc)] {
            if let bad = list.first(where: { !isBareAddress($0) }) {
                return "'\(field)' holds \(printable(bad)), which is not a bare address (a plain local@domain.example in ASCII, at most \(DirectDraft.maxAddressOctets) octets); display names are not accepted"
            }
        }
        guard !subject.isEmpty else { return "append_draft needs a subject that is not empty" }
        guard subject.utf8.count <= maxSubjectOctets else { return "'subject' is longer than \(maxSubjectOctets) octets" }
        if let fromName, fromName.utf8.count > maxFromNameOctets { return "'from_name' is longer than \(maxFromNameOctets) octets" }
        guard body.utf8.count <= maxBodyOctets else { return "'body' is longer than \(maxBodyOctets) octets" }
        if hasControlCharacter(subject) { return "'subject' holds a control character" }
        if let fromName, hasControlCharacter(fromName) { return "'from_name' holds a control character" }
        if body.unicodeScalars.contains(where: { $0.value == 0 }) { return "'body' holds a NUL character" }
        return nil
    }

    /// A bare address in the subset of RFC 5321 this tool accepts: a dot-atom
    /// local part of at most 64 octets, `@`, and a domain of at least two
    /// dot-separated labels of letters, digits and hyphens (no label empty,
    /// longer than 63 or starting or ending with a hyphen), at most 254 octets in
    /// all. No quoted local parts, domain literals or non-ASCII.
    static func isBareAddress(_ text: String) -> Bool {
        guard text.utf8.count <= DirectDraft.maxAddressOctets else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        let atext = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~".unicodeScalars)
        guard !local.isEmpty, local.utf8.count <= 64,
              local.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { atext.contains($0) } }) else { return false }
        let ldh = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".unicodeScalars)
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { ldh.contains($0) }
        }
    }

    private static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A refused value as it may be shown: cut short, control characters replaced.
    static func printable(_ text: String) -> String {
        let shown = String(String.UnicodeScalarView(text.unicodeScalars.prefix(80).map {
            ($0.value < 0x20 || $0.value == 0x7F) ? "?" : $0
        }))
        return "'\(shown)'"
    }

    static func render(_ result: AppendDraftResult) -> String {
        let object: [String: Any] = [
            "outcome": result.outcome.rawValue,
            "message_id": result.messageID,
            "mailbox": result.mailbox.map { $0 as Any } ?? NSNull(),
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
