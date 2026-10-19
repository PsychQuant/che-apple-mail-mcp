import Foundation
import SQLite3

/// #472 — writes ONE draft into Mail's Envelope Index exactly the way Mail
/// writes a not-yet-uploaded draft, for the opt-in experimental direct-draft
/// path. This is the only write path into the store in this codebase;
/// `.claude/rules/r-must-direct-db.md` carries the matching exception.
///
/// The row shapes are the ones validated live twice in #463 (S6, Round 2): the
/// rows below in a single `BEGIN IMMEDIATE` transaction, the .emlx renamed into
/// place inside it (so the `messages` row is never visible without its file),
/// `WriteTransactionGeneration` + 1, and `alleged_change_identifier` (the IMAP
/// sync token) never touched. Mail's own triggers maintain mailbox counts,
/// subjects and global-data cleanup.
public final class DraftStoreWriter {

    public struct Draft {
        public let mailboxRowId: Int64
        public let mailboxURL: String
        public let senderAddressRowId: Int64
        public let toAddresses: [String]
        public let subject: String
        public let messageIdHash: Int64
        public let messageIdHeader: String
        public let documentUUID: UUID
        public let size: Int
        public let flags: Int64
        public let date: Date

        public init(mailboxRowId: Int64, mailboxURL: String, senderAddressRowId: Int64, toAddresses: [String],
                    subject: String, messageIdHash: Int64, messageIdHeader: String, documentUUID: UUID,
                    size: Int, flags: Int64, date: Date) {
            self.mailboxRowId = mailboxRowId; self.mailboxURL = mailboxURL
            self.senderAddressRowId = senderAddressRowId; self.toAddresses = toAddresses
            self.subject = subject; self.messageIdHash = messageIdHash; self.messageIdHeader = messageIdHeader
            self.documentUUID = documentUUID; self.size = size; self.flags = flags; self.date = date
        }
    }

    public struct Inserted: Equatable {
        public let messageRowId: Int64
        public let conversationId: Int64
        public let globalDataRowId: Int64
        public let actionRowId: Int64
        public let messageIdHash: Int64
        public let emlxPath: String
    }

    public enum WriteError: Error, Equatable {
        case open(String), sql(String), noEmlxPath, emlxExists(String), emlxWrite(String),
             alreadyUploaded, unexpectedMailbox
    }

    /// The `messages` columns the insert was verified against (macOS 27.2,
    /// Mail 16.0). Any difference means the schema moved and the path is off.
    static let verifiedMessageColumns = [
        "ROWID", "message_id", "global_message_id", "remote_id", "document_id", "sender", "subject_prefix",
        "subject", "summary", "date_sent", "date_received", "mailbox", "remote_mailbox", "flags", "read",
        "flagged", "deleted", "size", "conversation_id", "date_last_viewed", "list_id_hash", "unsubscribe_type",
        "searchable_message", "brand_indicator", "display_date", "color", "type", "fuzzy_ancestor",
        "automated_conversation", "root_status", "flag_color", "is_urgent",
    ]

    /// Columns written (or read) in the other tables; extra columns there are fine.
    static let requiredColumns: [String: [String]] = [
        "message_global_data": ["message_id", "validation_state", "model_high_impact", "message_id_header"],
        "subjects": ["subject"],
        "conversations": ["conversation_id", "flags", "sync_key"],
        "conversation_id_message_id": ["conversation_id", "message_id", "date_sent"],
        "recipients": ["message", "address", "type", "position"],
        "searchable_messages": ["message_id", "message", "transaction_id", "message_body_indexed", "reindex_type"],
        "local_message_actions": ["mailbox", "source_mailbox", "destination_mailbox", "action_type", "user_initiated"],
        "action_messages": ["action", "action_phase", "message", "remote_id", "destination_message"],
        "properties": ["key", "value"],
        "addresses": ["address", "comment"],
        "mailboxes": ["url", "total_count"],
        "server_messages": ["message", "mailbox"],
    ]

    private var db: OpaquePointer?

    public init(databasePath: String) throws {
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db); db = nil
            throw WriteError.open(msg)
        }
        sqlite3_busy_timeout(db, 5000)
        _ = try? exec("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(db) }

    // MARK: - Checks and lookups

    /// Empty when the store matches what the insert was verified against.
    public func schemaDrift() -> [String] {
        var drift: [String] = []
        let messages = columns("messages")
        if messages != Self.verifiedMessageColumns {
            drift.append("messages columns differ from the verified set")
        }
        for (table, needed) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            let have = Set(columns(table))
            if have.isEmpty { drift.append("\(table) missing"); continue }
            let missing = needed.filter { !have.contains($0) }
            if !missing.isEmpty { drift.append("\(table) lacks \(missing.joined(separator: ","))") }
        }
        if (try? scalarInt("SELECT seq FROM sqlite_sequence WHERE name = 'messages'")) == nil {
            drift.append("sqlite_sequence has no messages row")
        }
        return drift
    }

    /// The `mailboxes` row of an account whose decoded path equals `pathComponents`.
    public func mailboxRow(accountUUID: String, pathComponents: [String]) -> (rowId: Int64, url: String)? {
        var hits: [(Int64, String)] = []
        query("SELECT ROWID, url FROM mailboxes WHERE url LIKE ?", [.text("%://\(accountUUID)/%")]) { st in
            let url = String(cString: sqlite3_column_text(st, 1))
            if let parsed = MailboxURL.decode(url), parsed.accountUUID == accountUUID,
               parsed.pathComponents == pathComponents {
                hits.append((sqlite3_column_int64(st, 0), url))
            }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// The `addresses` row this account's messages already use as sender for
    /// `address` (case-insensitive), most used first — Mail reuses one row
    /// (address + display name) per account identity.
    public func senderRow(address: String, accountUUID: String) -> (rowId: Int64, displayName: String)? {
        var result: (Int64, String)?
        query("""
            SELECT a.ROWID, a.comment, count(*) AS c FROM messages m
            JOIN addresses a ON a.ROWID = m.sender JOIN mailboxes mb ON mb.ROWID = m.mailbox
            WHERE a.address = ? COLLATE NOCASE AND mb.url LIKE ?
            GROUP BY a.ROWID ORDER BY c DESC LIMIT 1
            """, [.text(address), .text("%://\(accountUUID)/%")]) { st in
            let comment = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            result = (sqlite3_column_int64(st, 0), comment)
        }
        return result
    }

    /// `messages.read` of the inserted draft (nil if the row is gone).
    public func readFlag(_ ins: Inserted) -> Bool? {
        (try? scalarInt("SELECT read FROM messages WHERE ROWID = \(ins.messageRowId)"))?.map { $0 != 0 } ?? nil
    }

    public func uploadState(_ ins: Inserted) -> (remoteId: Int64?, actionQueued: Bool) {
        let remote = try? scalarInt("SELECT remote_id FROM messages WHERE ROWID = \(ins.messageRowId)")
        let queued = ((try? scalarInt("SELECT count(*) FROM local_message_actions WHERE ROWID = \(ins.actionRowId)")) ?? 0) > 0
        return (remote ?? nil, queued)
    }

    // MARK: - Write

    public func insert(_ d: Draft, emlx: Data) throws -> Inserted {
        let now = Int64(d.date.timeIntervalSince1970)
        try exec("BEGIN IMMEDIATE")
        var placed: String?
        do {
            guard let url = try scalarText("SELECT url FROM mailboxes WHERE ROWID = \(d.mailboxRowId)"),
                  url == d.mailboxURL, url.hasPrefix("imap://") else { throw WriteError.unexpectedMailbox }
            var toIds: [Int64] = []
            for addr in d.toAddresses {
                try run("INSERT OR IGNORE INTO addresses(address, comment) VALUES (?, '')", [.text(addr)])
                guard let id = try scalarInt("SELECT ROWID FROM addresses WHERE address = ? AND comment = ''", [.text(addr)]) else {
                    throw WriteError.sql("recipient address row missing")
                }
                toIds.append(id)
            }
            try run("INSERT INTO conversations(flags, sync_key) VALUES (0, NULL)")
            let cid = sqlite3_last_insert_rowid(db)
            try run("INSERT OR IGNORE INTO subjects(subject) VALUES (?)", [.text(d.subject)])
            guard let sid = try scalarInt("SELECT ROWID FROM subjects WHERE subject = ?", [.text(d.subject)]) else {
                throw WriteError.sql("subject row missing")
            }
            try run("INSERT INTO message_global_data(message_id, validation_state, model_high_impact, message_id_header) VALUES (?, 17940, 0, ?)",
                    [.int(d.messageIdHash), .text(d.messageIdHeader)])
            let gid = sqlite3_last_insert_rowid(db)
            guard let seq = try scalarInt("SELECT seq FROM sqlite_sequence WHERE name = 'messages'") else {
                throw WriteError.sql("no messages sequence")
            }
            let mid = seq + 1   // what AUTOINCREMENT assigns; the write lock is held
            try run("""
                INSERT INTO messages (ROWID, message_id, global_message_id, remote_id, document_id, sender, subject_prefix,
                    subject, summary, date_sent, date_received, mailbox, remote_mailbox, flags, read, flagged, deleted, size,
                    conversation_id, date_last_viewed, list_id_hash, unsubscribe_type, searchable_message, brand_indicator,
                    display_date, color, type, fuzzy_ancestor, automated_conversation, root_status, flag_color, is_urgent)
                VALUES (?, ?, ?, NULL, ?, ?, NULL, ?, NULL, ?, ?, ?, ?, ?, 1, 0, 0, ?, ?, ?, 0, NULL, ?, NULL, ?, NULL, 5, -2, 0, 1, 0, 0)
                """, [.int(mid), .int(d.messageIdHash), .int(gid), .blob(uuidBytes(d.documentUUID)), .int(d.senderAddressRowId),
                      .int(sid), .int(now), .int(now), .int(d.mailboxRowId), .int(d.mailboxRowId), .int(d.flags),
                      .int(Int64(d.size)), .int(cid), .int(now), .int(mid), .int(now)])
            placed = try placeEmlx(emlx, rowId: mid, mailboxURL: d.mailboxURL)
            try run("INSERT INTO conversation_id_message_id(conversation_id, message_id, date_sent) VALUES (?, ?, ?)",
                    [.int(cid), .int(d.messageIdHash), .int(now)])
            for (position, id) in toIds.enumerated() {
                try run("INSERT INTO recipients(message, address, type, position) VALUES (?, ?, 0, ?)",
                        [.int(mid), .int(id), .int(Int64(position))])
            }
            try run("INSERT INTO searchable_messages(message_id, message, transaction_id, message_body_indexed, reindex_type) VALUES (?, ?, 1, 1, 0)",
                    [.int(mid), .int(mid)])
            try run("INSERT INTO local_message_actions(mailbox, source_mailbox, destination_mailbox, action_type, user_initiated) VALUES (?, NULL, ?, 2, 1)",
                    [.int(d.mailboxRowId), .int(d.mailboxRowId)])
            let aid = sqlite3_last_insert_rowid(db)
            try run("INSERT INTO action_messages(action, action_phase, message, remote_id, destination_message) VALUES (?, 3, NULL, NULL, ?)",
                    [.int(aid), .int(mid)])
            guard let wtg = try scalarInt("SELECT value FROM properties WHERE key = 'WriteTransactionGeneration'") else {
                throw WriteError.sql("no WriteTransactionGeneration")
            }
            try run("UPDATE properties SET value = ? WHERE key = 'WriteTransactionGeneration'", [.int(wtg + 1)])
            try exec("COMMIT")
            return Inserted(messageRowId: mid, conversationId: cid, globalDataRowId: gid, actionRowId: aid,
                            messageIdHash: d.messageIdHash, emlxPath: placed!)
        } catch {
            _ = try? exec("ROLLBACK")
            if let p = placed { try? FileManager.default.removeItem(atPath: p) }
            throw error
        }
    }

    /// Exact reverse of `insert`. Refuses once a `server_messages` row exists:
    /// Mail has uploaded it, and cleanup must then go through Mail, not SQL.
    public func rollback(_ ins: Inserted) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            if ((try scalarInt("SELECT count(*) FROM server_messages WHERE message = \(ins.messageRowId)")) ?? 0) > 0 {
                throw WriteError.alreadyUploaded
            }
            try run("DELETE FROM action_messages WHERE destination_message = ?", [.int(ins.messageRowId)])
            try run("DELETE FROM local_message_actions WHERE ROWID = ?", [.int(ins.actionRowId)])
            try run("DELETE FROM recipients WHERE message = ?", [.int(ins.messageRowId)])
            try run("DELETE FROM searchable_messages WHERE message_id = ?", [.int(ins.messageRowId)])
            try run("DELETE FROM conversation_id_message_id WHERE conversation_id = ? AND message_id = ?",
                    [.int(ins.conversationId), .int(ins.messageIdHash)])
            try run("DELETE FROM messages WHERE ROWID = ?", [.int(ins.messageRowId)])
            try run("DELETE FROM conversations WHERE conversation_id = ?", [.int(ins.conversationId)])
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            throw error
        }
        try? FileManager.default.removeItem(atPath: ins.emlxPath)
    }

    // MARK: - File

    private func placeEmlx(_ data: Data, rowId: Int64, mailboxURL: String) throws -> String {
        guard let path = EmlxParser.newEmlxPath(rowId: Int(rowId), mailboxURL: mailboxURL) else {
            throw WriteError.noEmlxPath
        }
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { throw WriteError.emlxWrite(error.localizedDescription) }
        guard !fm.fileExists(atPath: path) else { throw WriteError.emlxExists(path) }
        let tmp = "\(dir)/.direct-draft-\(rowId)-\(UUID().uuidString).tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            try fm.moveItem(atPath: tmp, toPath: path)
        } catch {
            try? fm.removeItem(atPath: tmp)
            throw WriteError.emlxWrite(error.localizedDescription)
        }
        return path
    }

    private func uuidBytes(_ u: UUID) -> Data {
        withUnsafeBytes(of: u.uuid) { Data($0) }
    }

    // MARK: - SQLite helpers

    private enum Value { case int(Int64), text(String), blob(Data) }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw WriteError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw WriteError.sql(String(cString: sqlite3_errmsg(db)))
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(v.count), transient) }
            }
        }
        return st
    }

    private func run(_ sql: String, _ args: [Value] = []) throws {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_DONE else { throw WriteError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    private func scalarInt(_ sql: String, _ args: [Value] = []) throws -> Int64? {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(st, 0)
    }

    private func scalarText(_ sql: String, _ args: [Value] = []) throws -> String? {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    private func query(_ sql: String, _ args: [Value], _ row: (OpaquePointer?) -> Void) {
        guard let st = try? prepare(sql, args) else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }

    private func columns(_ table: String) -> [String] {
        var names: [String] = []
        query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { st in
            names.append(String(cString: sqlite3_column_text(st, 0)))
        }
        return names
    }
}
