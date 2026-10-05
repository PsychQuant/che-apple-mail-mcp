import Foundation
import MailSQLite

/// #472 — the trigger: Mail must first list the new draft (its model notices an
/// external insert within seconds, #463), then a read-status toggle false → true
/// creates a Mail-originated action, which wakes the sync engine; it processes
/// every action above its cursor, the injected upload included (#463 Round 2:
/// uploaded 1.8 s after toggling the draft's own read status).
func buildDirectDraftTriggerScript(rowId: Int64) -> String {
    """
    tell application "Mail"
        set _m to missing value
        repeat 40 times
            try
                set _m to (first message of drafts mailbox whose id is \(rowId))
                exit repeat
            end try
            delay 0.25
        end repeat
        if _m is missing value then error "DIRECTDRAFT: Mail did not list the new draft within 10 s"
        set read status of _m to false
        delay 0.5
        set read status of _m to true
        return "toggled"
    end tell
    """
}

/// #472 live: with a 0.3 s gap between the two toggles, one of two drafts ended
/// unread locally while the server had it read. After the upload the path
/// re-asserts read status with this script when the row still says unread.
func buildDirectDraftMarkReadScript(rowId: Int64) -> String {
    """
    tell application "Mail"
        set _m to (first message of drafts mailbox whose id is \(rowId))
        set read status of _m to true
        return "read"
    end tell
    """
}

extension MailController {
    /// Runs the trigger through the cancellable `osascript` transport (#406).
    func triggerDirectDraftUpload(rowId: Int64) throws -> String {
        try runDraftScanScript(buildDirectDraftTriggerScript(rowId: rowId), timeout: 20)
    }

    func markDirectDraftRead(rowId: Int64) throws -> String {
        try runDraftScanScript(buildDirectDraftMarkReadScript(rowId: rowId), timeout: 10)
    }
}

/// #472 — EXPERIMENTAL: write a draft straight into Mail's store, then have Mail
/// upload it. Every step that could go wrong before the trigger falls back to the
/// GUI path; after the trigger there is no fallback (it would duplicate the draft).
struct DirectDraftPath {
    let controller: MailController
    let reader: EnvelopeIndexReader?
    var enabled: Bool = DirectDraft.isEnabled
    var databasePath: String = EnvelopeIndexReader.defaultDatabasePath
    var mailInfoPlist: String = "/System/Applications/Mail.app/Contents/Info.plist"
    var uploadDeadline: TimeInterval = 10

    /// Why an attempt stopped before writing. `reason` is the human text of the
    /// GUI-path note (unchanged since #472); `code` is the fixed timing-CSV code
    /// (#475) — a closed list, kept free of commas because the CSV is unquoted.
    enum Gate: Equatable {
        case ineligible(DirectDraft.Ineligible)
        case version
        case account(count: Int)
        case index
        case draftsUnidentified(String)
        case draftsUnmatched
        case writerOpen(String)
        case schemaDrift([String])
        case mailbox
        case sender
        case insert(String)

        var code: String {
            switch self {
            case .ineligible(let i): return String(describing: i)
            case .version: return "version"
            case .account: return "account"
            case .index: return "index"
            case .draftsUnidentified: return "drafts_unidentified"
            case .draftsUnmatched: return "drafts_unmatched"
            case .writerOpen: return "writer_open"
            case .schemaDrift: return "schema_drift"
            case .mailbox: return "mailbox"
            case .sender: return "sender"
            case .insert: return "insert"
            }
        }

        var reason: String {
            switch self {
            case .ineligible(let i): return i.reason
            case .version: return "Mail/macOS version outside the verified range (Mail 16, macOS 27)"
            case .account(let n): return "from_address maps to \(n) accounts, not exactly one"
            case .index: return "the Envelope Index is not readable"
            case .draftsUnidentified(let why): return "could not identify the Drafts mailbox: \(why)"
            case .draftsUnmatched: return "the Drafts mailbox could not be matched to the index"
            case .writerOpen(let why): return "the store could not be opened for writing: \(why)"
            case .schemaDrift(let drift): return "store schema differs from the verified one (\(drift.joined(separator: "; ")))"
            case .mailbox: return "the Drafts mailbox is not a single IMAP mailbox row"
            case .sender: return "no existing sender row for from_address in this account"
            case .insert(let why): return "the direct write failed and was rolled back: \(why)"
            }
        }
    }

    enum Outcome: Equatable {
        /// Not tried; `nil` = the flag is off (no note, no timing rows).
        case notAttempted(Gate?)
        /// Draft written and handed to Mail. The text is the tool result;
        /// `pending` = the upload was requested but not confirmed in time.
        case created(String, pending: Bool)
        /// Written, then rolled back before Mail had it; the GUI path should run.
        case fellBack(String)

        /// The `outcome` column of this attempt's `direct` timing rows (#475);
        /// nil when the attempt did not run at all.
        var timingCode: String? {
            switch self {
            case .notAttempted(nil): return nil
            case .notAttempted(let gate?): return "not_attempted:\(gate.code)"
            case .created(_, let pending): return pending ? "created:upload_pending" : "created"
            case .fellBack: return "fell_back:trigger"
            }
        }
    }

    /// #475 — the whole `create_draft` call as one timing run: the direct-write
    /// attempt (when enabled) and, unless it created the draft, the GUI path,
    /// whose result then carries the fallback note. `csvPath` nil = timing off.
    static func createDraft(csvPath: String?, directEnabled: Bool,
                            direct: () async -> Outcome,
                            gui: () async throws -> String) async throws -> String {
        try await ComposeTiming.withRun(csvPath: csvPath) {
            var note = ""
            if directEnabled {
                switch await direct() {
                case .created(let text, _): return text
                case .notAttempted(let gate): note = gate.map { fallbackNote($0.reason) } ?? ""
                case .fellBack(let reason): note = fallbackNote(reason)
                }
            }
            return try await gui() + note
        }
    }

    static func fallbackNote(_ reason: String) -> String {
        " [experimental direct-write not used: \(reason) — GUI path]"
    }

    func attempt(to: [String], subject: String, body: String, cc: [String]?, bcc: [String]?,
                 attachments: [String]?, format: BodyFormat, fromAddress: String?) async -> Outcome {
        let timer = DirectDraftTimer(fromAddressSet: !(fromAddress ?? "").isEmpty)
        timer.mark("enter")
        let outcome = await attemptSteps(to: to, subject: subject, body: body, cc: cc, bcc: bcc,
                                         attachments: attachments, format: format, fromAddress: fromAddress,
                                         timer: timer)
        timer.finish(outcome)
        return outcome
    }

    private func attemptSteps(to: [String], subject: String, body: String, cc: [String]?, bcc: [String]?,
                              attachments: [String]?, format: BodyFormat, fromAddress: String?,
                              timer: DirectDraftTimer) async -> Outcome {
        if let no = DirectDraft.eligibility(enabled: enabled, format: format, to: to, cc: cc ?? [], bcc: bcc ?? [],
                                            attachments: attachments ?? [], subject: subject, fromAddress: fromAddress) {
            return .notAttempted(no == .disabled ? nil : .ineligible(no))
        }
        timer.mark("eligibility")
        let from = fromAddress!
        guard let version = mailVersion(), version.short.hasPrefix("16."),
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            return .notAttempted(.version)
        }
        timer.mark("version_gate")
        let uuids = AccountMapper.uuids(forEmail: from)
        guard uuids.count == 1, let account = uuids.first else {
            return .notAttempted(.account(count: uuids.count))
        }
        guard let reader else { return .notAttempted(.index) }

        // Drafts mailbox: the sanctioned identification (r-must-direct-db #186),
        // then the #345 corroborated join to a path, then exactly one row.
        let special: [String: Any]
        do { special = try await controller.getSpecialMailboxes(accountId: account) }
        catch { return .notAttempted(.draftsUnidentified(error.localizedDescription)) }
        let entries: [(path: String, components: [String])] = ((try? reader.listMailboxes(accountId: account)) ?? [])
            .compactMap { row in
                guard let name = row["name"] as? String else { return nil }
                return (name, (row["path_components"] as? [String]) ?? [name])
            }
        let leaves = perAccountSpecialMailboxes.compactMap { s in (special[s.key] as? String).map { (key: s.key, leaf: $0) } }
        guard let draftsPath = joinSpecialMailboxPaths(leaves: leaves, mailboxes: entries)["drafts"],
              let components = entries.first(where: { $0.path == draftsPath })?.components else {
            return .notAttempted(.draftsUnmatched)
        }
        timer.mark("drafts_resolved")

        let writer: DraftStoreWriter
        do { writer = try DraftStoreWriter(databasePath: databasePath) }
        catch { return .notAttempted(.writerOpen("\(error)")) }
        let drift = writer.schemaDrift()
        guard drift.isEmpty else { return .notAttempted(.schemaDrift(drift)) }
        timer.mark("writer_opened")
        guard let mailbox = writer.mailboxRow(accountUUID: account, pathComponents: components),
              mailbox.url.hasPrefix("imap://") else {
            return .notAttempted(.mailbox)
        }
        guard let sender = writer.senderRow(address: from, accountUUID: account) else {
            return .notAttempted(.sender)
        }

        let now = Date()
        let message = DirectDraft.buildMessage(
            fromName: sender.displayName.isEmpty ? nil : sender.displayName, fromAddress: from, to: to,
            subject: subject, body: body, date: now, documentUUID: UUID(), messageIdLocalPart: UUID(),
            boundary: UUID(), mailVersion: "\(version.short) (\(version.build))")
        let draft = DraftStoreWriter.Draft(
            mailboxRowId: mailbox.rowId, mailboxURL: mailbox.url, senderAddressRowId: sender.rowId,
            toAddresses: to, subject: subject, messageIdHash: DirectDraft.messageIdHash(message.messageIdNoBrackets),
            messageIdHeader: "<\(message.messageIdNoBrackets)>", documentUUID: UUID(), size: message.size,
            flags: DirectDraft.draftFlags, date: now)
        let inserted: DraftStoreWriter.Inserted
        do { inserted = try writer.insert(draft, emlx: DirectDraft.emlx(mime: message.mime, flags: DirectDraft.draftFlags, date: now)) }
        catch { return .notAttempted(.insert("\(error)")) }
        timer.mark("inserted")

        let triggered = Date()
        do {
            _ = try await controller.triggerDirectDraftUpload(rowId: inserted.messageRowId)
            timer.mark("trigger_sent")
        } catch {
            do {
                try writer.rollback(inserted)
                return .fellBack("Mail could not be asked to upload it (\(error.localizedDescription)); the write was rolled back")
            } catch {
                // Rollback refused: the server already has it. It is created.
                return .created(Self.createdText(seconds: Date().timeIntervalSince(triggered), uploaded: true), pending: false)
            }
        }
        while Date().timeIntervalSince(triggered) < uploadDeadline {
            let state = writer.uploadState(inserted)
            if state.remoteId != nil && !state.actionQueued {
                let seconds = Date().timeIntervalSince(triggered)
                timer.mark("uploaded")
                let read = await ensureRead(writer, inserted)
                if read.confirmed { timer.mark("read_ensured") }
                return .created(Self.createdText(seconds: seconds, uploaded: true) + read.note, pending: false)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .created(Self.createdText(seconds: uploadDeadline, uploaded: false), pending: true)
    }

    /// What one look at the uploaded draft's local read flag means (#475 verify
    /// R2): only an observed `read = 1` is a confirmation; a row that cannot be
    /// read is NOT, even though no repair is attempted for it.
    enum ReadCheck: Equatable { case confirmed, needsRepair, unknown }

    static func readCheck(_ flag: Bool?) -> ReadCheck {
        switch flag {
        case true?: return .confirmed
        case false?: return .needsRepair
        case nil: return .unknown
        }
    }

    /// Re-assert read status once if the uploaded draft's row still says unread
    /// (see `buildDirectDraftMarkReadScript`). `confirmed` is true only when the
    /// row was seen as read; `note` explains anything else.
    private func ensureRead(_ writer: DraftStoreWriter, _ inserted: DraftStoreWriter.Inserted) async
        -> (note: String, confirmed: Bool) {
        switch Self.readCheck(writer.readFlag(inserted)) {
        case .confirmed: return ("", true)
        case .unknown: return (" [note: the draft is uploaded but its local read status could not be read]", false)
        case .needsRepair: break
        }
        _ = try? await controller.markDirectDraftRead(rowId: inserted.messageRowId)
        for _ in 0..<8 {
            if Self.readCheck(writer.readFlag(inserted)) == .confirmed { return ("", true) }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return (" [note: the draft is uploaded but still shows as unread locally]", false)
    }

    static func createdText(seconds: TimeInterval, uploaded: Bool) -> String {
        uploaded
            ? String(format: "Draft created successfully (experimental direct-write path, #472; uploaded %.1fs after the trigger)", seconds)
            : String(format: "Draft created (experimental direct-write path, #472) — upload pending after %.0fs: the draft is in Mail's Drafts and Mail uploads it with its next action for this account", seconds)
    }

    private func mailVersion() -> (short: String, build: String)? {
        guard let info = NSDictionary(contentsOfFile: mailInfoPlist),
              let short = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        return (short, build)
    }
}

/// #475 — the `direct` segment of a `create_draft` timing run. Inert (no clock
/// reads, nothing recorded) unless a run is active, i.e. unless
/// `CHE_MAIL_COMPOSE_TIMING_CSV` is set; a mark is taken when a step COMPLETES.
final class DirectDraftTimer: @unchecked Sendable {
    private let run = ComposeTiming.currentRun
    private let fromAddressSet: Bool
    private let lock = NSLock()
    private var marks: [ComposeTiming.Mark] = []

    init(fromAddressSet: Bool) { self.fromAddressSet = fromAddressSet }

    func mark(_ label: String) {
        guard run != nil else { return }
        let mark = ComposeTiming.Mark(source: "swift", label: label, time: Date().timeIntervalSinceReferenceDate)
        lock.lock(); marks.append(mark); lock.unlock()
    }

    /// Adds the segment to the run; nothing when the attempt did not run at all
    /// (flag off) or no run is active.
    func finish(_ outcome: DirectDraftPath.Outcome) {
        guard let run, let code = outcome.timingCode else { return }
        mark("returned")
        lock.lock(); let collected = marks; lock.unlock()
        run.add(ComposeTiming.Segment(path: ComposeTiming.directPath, outcome: code,
                                      config: ["from_address_set": fromAddressSet ? "true" : "false"],
                                      marks: collected))
    }
}
