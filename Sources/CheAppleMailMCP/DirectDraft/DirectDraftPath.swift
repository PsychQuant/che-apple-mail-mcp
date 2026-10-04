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

    enum Outcome: Equatable {
        /// Not tried; `nil` reason = the flag is off (no note at all).
        case notAttempted(String?)
        /// Draft written and handed to Mail. The text is the tool result.
        case created(String)
        /// Written, then rolled back before Mail had it; the GUI path should run.
        case fellBack(String)
    }

    static func fallbackNote(_ reason: String) -> String {
        " [experimental direct-write not used: \(reason) — GUI path]"
    }

    func attempt(to: [String], subject: String, body: String, cc: [String]?, bcc: [String]?,
                 attachments: [String]?, format: BodyFormat, fromAddress: String?) async -> Outcome {
        if let no = DirectDraft.eligibility(enabled: enabled, format: format, to: to, cc: cc ?? [], bcc: bcc ?? [],
                                            attachments: attachments ?? [], subject: subject, fromAddress: fromAddress) {
            return .notAttempted(no == .disabled ? nil : no.reason)
        }
        let from = fromAddress!
        guard let version = mailVersion(), version.short.hasPrefix("16."),
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            return .notAttempted("Mail/macOS version outside the verified range (Mail 16, macOS 27)")
        }
        let uuids = AccountMapper.uuids(forEmail: from)
        guard uuids.count == 1, let account = uuids.first else {
            return .notAttempted("from_address maps to \(uuids.count) accounts, not exactly one")
        }
        guard let reader else { return .notAttempted("the Envelope Index is not readable") }

        // Drafts mailbox: the sanctioned identification (r-must-direct-db #186),
        // then the #345 corroborated join to a path, then exactly one row.
        let special: [String: Any]
        do { special = try await controller.getSpecialMailboxes(accountId: account) }
        catch { return .notAttempted("could not identify the Drafts mailbox: \(error.localizedDescription)") }
        let entries: [(path: String, components: [String])] = ((try? reader.listMailboxes(accountId: account)) ?? [])
            .compactMap { row in
                guard let name = row["name"] as? String else { return nil }
                return (name, (row["path_components"] as? [String]) ?? [name])
            }
        let leaves = perAccountSpecialMailboxes.compactMap { s in (special[s.key] as? String).map { (key: s.key, leaf: $0) } }
        guard let draftsPath = joinSpecialMailboxPaths(leaves: leaves, mailboxes: entries)["drafts"],
              let components = entries.first(where: { $0.path == draftsPath })?.components else {
            return .notAttempted("the Drafts mailbox could not be matched to the index")
        }

        let writer: DraftStoreWriter
        do { writer = try DraftStoreWriter(databasePath: databasePath) }
        catch { return .notAttempted("the store could not be opened for writing: \(error)") }
        let drift = writer.schemaDrift()
        guard drift.isEmpty else { return .notAttempted("store schema differs from the verified one (\(drift.joined(separator: "; ")))") }
        guard let mailbox = writer.mailboxRow(accountUUID: account, pathComponents: components),
              mailbox.url.hasPrefix("imap://") else {
            return .notAttempted("the Drafts mailbox is not a single IMAP mailbox row")
        }
        guard let sender = writer.senderRow(address: from, accountUUID: account) else {
            return .notAttempted("no existing sender row for from_address in this account")
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
        catch { return .notAttempted("the direct write failed and was rolled back: \(error)") }

        let triggered = Date()
        do {
            _ = try await controller.triggerDirectDraftUpload(rowId: inserted.messageRowId)
        } catch {
            do {
                try writer.rollback(inserted)
                return .fellBack("Mail could not be asked to upload it (\(error.localizedDescription)); the write was rolled back")
            } catch {
                // Rollback refused: the server already has it. It is created.
                return .created(Self.createdText(seconds: Date().timeIntervalSince(triggered), uploaded: true))
            }
        }
        while Date().timeIntervalSince(triggered) < uploadDeadline {
            let state = writer.uploadState(inserted)
            if state.remoteId != nil && !state.actionQueued {
                let seconds = Date().timeIntervalSince(triggered)
                return .created(Self.createdText(seconds: seconds, uploaded: true) + (await ensureRead(writer, inserted)))
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .created(Self.createdText(seconds: uploadDeadline, uploaded: false))
    }

    /// Re-assert read status once if the uploaded draft's row still says unread
    /// (see `buildDirectDraftMarkReadScript`). Returns a note only on failure.
    private func ensureRead(_ writer: DraftStoreWriter, _ inserted: DraftStoreWriter.Inserted) async -> String {
        guard writer.readFlag(inserted) == false else { return "" }
        _ = try? await controller.markDirectDraftRead(rowId: inserted.messageRowId)
        for _ in 0..<8 {
            if writer.readFlag(inserted) == true { return "" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return " [note: the draft is uploaded but still shows as unread locally]"
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
