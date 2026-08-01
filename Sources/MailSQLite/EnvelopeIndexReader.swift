import Foundation
import SQLite3

/// Read-only interface to Apple Mail's Envelope Index SQLite database.
/// Provides millisecond-level email search by directly querying the index
/// instead of going through AppleScript.
///
/// Thread safety: SQLite readonly connections in WAL mode support
/// concurrent readers, so this class does not need actor serialization.
public final class EnvelopeIndexReader {

    // MARK: - Constants

    private static let mailDataVersion = "V10"

    /// Default path to the Envelope Index database.
    public static var defaultDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Mail/\(mailDataVersion)/MailData/Envelope Index"
    }

    /// Lock guarding `_mailStoragePathOverride`. Tests mutate the override
    /// from arbitrary threads (XCTest currently runs serially on this
    /// target, but we don't want to rely on that assumption — see #9
    /// verify round 2).
    private static let _mailStoragePathOverrideLock = NSLock()
    private nonisolated(unsafe) static var _mailStoragePathOverride: String?

    /// Test-only override for `mailStoragePath`. Reads and writes are
    /// serialized through `_mailStoragePathOverrideLock`, so concurrent
    /// test execution (if ever enabled) produces consistent values within
    /// each critical section. **Tests that mutate this property must still
    /// save/restore the previous value under a common scope** — the lock
    /// prevents torn reads, not logical races between overlapping tests.
    ///
    /// Declared `internal` so that release builds of external Swift
    /// modules (e.g., CheAppleMailMCP) cannot mutate it; tests access it
    /// via `@testable import`.
    static var mailStoragePathOverride: String? {
        get {
            _mailStoragePathOverrideLock.lock()
            defer { _mailStoragePathOverrideLock.unlock() }
            return _mailStoragePathOverride
        }
        set {
            _mailStoragePathOverrideLock.lock()
            defer { _mailStoragePathOverrideLock.unlock() }
            _mailStoragePathOverride = newValue
        }
    }

    /// Base path for mail storage (account directories).
    public static var mailStoragePath: String {
        if let override = mailStoragePathOverride {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Mail/\(mailDataVersion)"
    }

    // MARK: - Properties

    private var db: OpaquePointer?

    /// Mapping from account UUID to human-readable account name.
    private var accountMap: [String: String]

    /// Reverse index: display_name → list of UUIDs. Rebuilt whenever
    /// `accountMap` is set. List form (not single value) surfaces
    /// multi-account-same-display-name collisions to callers — see #101.
    private var reverseAccountMap: [String: [String]]

    // MARK: - Initialization

    /// Open the Envelope Index database in read-only mode.
    ///
    /// - Parameters:
    ///   - databasePath: Path to the Envelope Index SQLite file.
    ///   - accountMapping: UUID → account name mapping. Defaults to reading
    ///     AccountsMap.plist via `AccountMapper.buildMapping()` (no AppleScript).
    /// - Throws: `MailSQLiteError.databaseNotAccessible` if the file
    ///   does not exist or cannot be opened (e.g., missing Full Disk Access).
    public init(databasePath: String, accountMapping: [String: String]? = nil) throws {
        let mapping = accountMapping ?? AccountMapper.buildMapping()
        self.accountMap = mapping
        self.reverseAccountMap = Self.buildReverseMap(from: mapping)

        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw MailSQLiteError.databaseNotAccessible(
                FullDiskAccessHelp.guidance(
                    reason: "Database does not exist or is unreadable at \(databasePath)."
                )
            )
        }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(databasePath, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw MailSQLiteError.databaseNotAccessible(
                FullDiskAccessHelp.guidance(reason: "Failed to open database: \(msg).")
            )
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Account Mapping

    /// Resolve an account UUID to a human-readable name.
    /// Falls back to the UUID itself if no mapping exists.
    public func accountName(for uuid: String) -> String {
        accountMap[uuid] ?? uuid
    }

    /// Update the account mapping (e.g., after querying AppleScript).
    public func updateAccountMapping(_ mapping: [String: String]) {
        accountMap = mapping
        reverseAccountMap = Self.buildReverseMap(from: mapping)
    }

    /// Reverse lookup: display name → list of UUIDs that map to it.
    ///
    /// Returns an empty array for unknown names. When 2+ UUIDs share the
    /// same display name (e.g., iCloud catch-all alias + Gmail with the
    /// same address), all are returned — callers can detect collision via
    /// `.count > 1` and decide whether to surface a disambiguation hint.
    ///
    /// Backs the 4 previously-duplicated O(n) reverse-lookup callsites
    /// inside this file. Externally, sets up the collision-aware path for
    /// the `#101` `account_id` fix.
    public func accountUUIDs(forName name: String) -> [String] {
        reverseAccountMap[name] ?? []
    }

    /// Build the reverse index in O(n). Called from `init` and
    /// `updateAccountMapping` to keep the index in sync with `accountMap`.
    private static func buildReverseMap(from mapping: [String: String]) -> [String: [String]] {
        var rev: [String: [String]] = [:]
        for (uuid, name) in mapping {
            rev[name, default: []].append(uuid)
        }
        return rev
    }

    /// Build account mapping by scanning the mail storage directory
    /// for UUID-formatted subdirectories. This is a filesystem-only
    /// fallback that uses UUIDs as names.
    public static func scanAccountUUIDs(
        storagePath: String? = nil
    ) -> [String] {
        let basePath = storagePath ?? mailStoragePath
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: basePath) else {
            return []
        }
        // Account directories are UUID-formatted (8-4-4-4-12)
        return contents.filter { name in
            name.count == 36
            && name.split(separator: "-").count == 5
            && name.allSatisfy { $0.isHexDigit || $0 == "-" }
        }
    }

    // MARK: - Account & Mailbox Queries

    /// List accounts from the filesystem (AccountsMap.plist).
    ///
    /// Fallback path for `list_accounts` when Mail.app is unavailable. Because
    /// the plist has no `user_name` or `email_addresses` field, EWS accounts
    /// resolve to UUID-as-display-name (see #9 and #11). Use the AppleScript
    /// path in `MailController.listAccounts` as the primary resolver for
    /// accurate EWS email addresses.
    ///
    /// Returns the same JSON schema as `MailController.listAccounts` so callers
    /// can consume either path uniformly. Fields that cannot be resolved from
    /// the filesystem (`user_name`, `email_addresses`) are empty for EWS.
    public func listAccounts() -> [[String: Any]] {
        let uuids = Self.scanAccountUUIDs()
        return uuids.map { uuid in
            let mappedName = accountName(for: uuid)
            // Honest about filesystem-only limits: if AccountMapper could parse
            // an email out of AccountURL (IMAP style), surface it in both `name`
            // and `display_name`. For EWS, mappedName == uuid per #9's fallback,
            // so user_name and email_addresses stay empty.
            let hasEmail = mappedName.contains("@")
            return [
                "name": mappedName,
                "user_name": hasEmail ? mappedName : "",
                "id": uuid,
                "email_addresses": hasEmail ? [mappedName] : [],
                "display_name": mappedName,
                "enabled": true,
                "uuid": uuid  // legacy field, keep for backward compat
            ]
        }
    }

    /// List mailboxes from the SQLite mailboxes table.
    /// - Parameters:
    ///   - accountName: Optional account filter (display name or email-form,
    ///     resolved via the account mapping).
    ///   - accountId: Optional account UUID escape hatch (#202). Non-empty wins
    ///     over `accountName` and filters by UUID directly.
    /// - Throws: `MailSQLiteError.accountNotResolvable` if a non-empty
    ///   `accountName` resolves to no configured account (never silently returns
    ///   every account's mailboxes — the #202 latent bug).
    public func listMailboxes(accountName: String? = nil, accountId: String? = nil) throws -> [[String: Any]] {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        var sql = "SELECT url, total_count, unread_count FROM mailboxes"
        var bindings: [String] = []

        // #202: resolve the account scope to a UUID. A non-empty `accountId` wins
        // (the escape hatch). Otherwise a given `accountName` MUST resolve to a
        // UUID — if it doesn't, THROW rather than silently dropping the WHERE
        // clause (which returned *every* account's mailboxes). No selector → all.
        if let accountId = accountId, !accountId.isEmpty {
            sql += " WHERE url LIKE ?"
            bindings.append("%://\(accountId)/%")
        } else if let accountName = accountName, !accountName.isEmpty {
            guard let uuid = accountUUIDs(forName: accountName).first else {
                throw MailSQLiteError.accountNotResolvable(name: accountName)
            }
            sql += " WHERE url LIKE ?"
            bindings.append("%://\(uuid)/%")
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, binding) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let url = columnText(stmt, 0)
            let totalCount = Int(sqlite3_column_int(stmt, 1))
            let unreadCount = Int(sqlite3_column_int(stmt, 2))

            guard let parsed = MailboxURL.decode(url) else { continue }
            let acctName = self.accountName(for: parsed.accountUUID)

            results.append([
                "name": parsed.mailboxPath,
                "account_name": acctName,
                "total_count": totalCount,
                "unread_count": unreadCount
            ])
        }
        return results
    }

    /// List emails in a mailbox via SQLite.
    /// List with truncation detection: fetches up to `limit + 1` rows so the
    /// caller can tell whether more existed than were returned (#204).
    public func listEmailsPage(mailbox: String, accountName: String, limit rawLimit: Int = 50) throws -> (results: [[String: Any]], truncated: Bool) {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        // Clamp limit: negative would trap `prefix()`, above Int32.max-1 would
        // overflow the `+1` bind. Negative → 0 (empty, crash-free). (#204)
        let limit = min(max(rawLimit, 0), Int(Int32.max) - 1)

        var conditions = ["m.deleted = 0"]
        var bindings: [String] = []

        // Account filter
        let accountUUID = accountUUIDs(forName: accountName).first
        if let uuid = accountUUID {
            conditions.append("mb.url LIKE ?")
            bindings.append("%://\(uuid)/%")
        }

        // Mailbox filter (#317): decode-side ROWID resolution, not encode+LIKE.
        let mailboxIds = try mailboxRowIds(matchingPath: mailbox, accountUUID: accountUUID)
        conditions.append(Self.rowIdInCondition("m.mailbox", mailboxIds))

        let sql = """
            SELECT m.ROWID, s.subject, a.address, a.comment, m.date_received
            FROM messages m
            JOIN subjects s ON m.subject = s.ROWID
            JOIN addresses a ON m.sender = a.ROWID
            JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.date_received DESC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for binding in bindings {
            sqlite3_bind_text(stmt, idx, binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            idx += 1
        }
        // Fetch one extra row to detect truncation definitively (#204).
        let fetchLimit = limit + 1
        sqlite3_bind_int(stmt, idx, Int32(fetchLimit))

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = Int(sqlite3_column_int64(stmt, 0))
            let subject = columnText(stmt, 1)
            let senderAddr = columnText(stmt, 2)
            let senderName = columnText(stmt, 3)
            let sender = senderName.isEmpty ? senderAddr : "\(senderName) <\(senderAddr)>"
            results.append([
                "id": String(rowId),
                "subject": subject,
                "sender": sender
            ])
        }
        let truncated = results.count > limit
        return (Array(results.prefix(limit)), truncated)
    }

    /// Backward-compatible array form — returns at most `limit` results without
    /// the truncation flag. Prefer `listEmailsPage` when truncation matters (#204).
    public func listEmails(mailbox: String, accountName: String, limit: Int = 50) throws -> [[String: Any]] {
        try listEmailsPage(mailbox: mailbox, accountName: accountName, limit: limit).results
    }

    /// Get unread count via SQLite mailboxes table.
    public func getUnreadCount(mailbox: String? = nil, accountName: String? = nil) throws -> Int {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        var sql = "SELECT SUM(unread_count) FROM mailboxes"
        var conditions: [String] = []
        var bindings: [String] = []

        var accountUUID: String?
        if let accountName = accountName, let uuid = accountUUIDs(forName: accountName).first {
            accountUUID = uuid
            conditions.append("url LIKE ?")
            bindings.append("%://\(uuid)/%")
        }
        if let mailbox = mailbox {
            // #317: decode-side ROWID resolution, not encode+LIKE. This query
            // runs over the mailboxes table itself, so filter its own ROWID.
            let ids = try mailboxRowIds(matchingPath: mailbox, accountUUID: accountUUID)
            conditions.append(Self.rowIdInCondition("ROWID", ids))
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, binding) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// List attachments for a message via SQLite.
    public func listAttachments(messageId: Int) throws -> [[String: Any]] {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        let sql = "SELECT name, attachment_id FROM attachments WHERE message = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(messageId))

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append([
                "name": columnText(stmt, 0),
                "attachment_id": columnText(stmt, 1)
            ])
        }
        return results
    }

    /// Get email metadata from SQLite messages table.
    public func getEmailMetadata(messageId: Int) throws -> [String: Any] {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        let sql = """
            SELECT m.read, m.flagged, m.deleted, m.size, m.date_received,
                   m.conversation_id, s.subject, a.address, mb.url
            FROM messages m
            JOIN subjects s ON m.subject = s.ROWID
            JOIN addresses a ON m.sender = a.ROWID
            JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE m.ROWID = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(messageId))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw MailSQLiteError.queryFailed("Message \(messageId) not found")
        }

        let dateReceived = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
        return [
            "read": sqlite3_column_int(stmt, 0) != 0,
            "flagged": sqlite3_column_int(stmt, 1) != 0,
            "deleted": sqlite3_column_int(stmt, 2) != 0,
            "size": Int(sqlite3_column_int64(stmt, 3)),
            "date_received": ISO8601DateFormatter().string(from: dateReceived),
            "conversation_id": Int(sqlite3_column_int64(stmt, 5)),
            "subject": columnText(stmt, 6),
            "sender": columnText(stmt, 7),
            "mailbox": MailboxURL.decode(columnText(stmt, 8))?.mailboxPath ?? columnText(stmt, 8)
        ]
    }

    /// List VIP senders from VIPMailboxes.plist.
    public func listVIPSenders() -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/Library/Mail/V10/MailData/VIPMailboxes.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [[String: Any]] else {
            return []
        }
        return plist
    }

    // MARK: - Message Lookup

    /// Get the raw mailbox URL for a given message ROWID.
    /// Needed to resolve .emlx file paths.
    public func mailboxURL(forMessageId id: Int) throws -> String? {
        guard let db = db else {
            throw MailSQLiteError.queryFailed("Database not open")
        }
        let sql = "SELECT mb.url FROM messages m JOIN mailboxes mb ON m.mailbox = mb.ROWID WHERE m.ROWID = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(id))
        if sqlite3_step(stmt) == SQLITE_ROW {
            return columnText(stmt, 0)
        }
        return nil
    }

    // MARK: - Search

    /// Search emails using the Envelope Index.
    ///
    /// - Parameter params: Search parameters (query, field, filters, sort, limit).
    /// - Returns: Array of search results.
    /// - Throws: `MailSQLiteError.queryFailed` on SQLite errors.
    /// Search with truncation detection: fetches up to `limit + 1` rows so the
    /// caller can tell whether more matched than were returned (#204).
    public func searchPage(_ params: SearchParameters) throws -> (results: [SearchResult], truncated: Bool) {
        guard let db = db else {
            throw MailSQLiteError.queryFailed("Database not open")
        }

        // Clamp limit before use: a negative value would trap `prefix()`, and a
        // value above Int32.max-1 would overflow the `+1` bind. Negative → 0
        // (empty result, crash-free). (#204 verify CRITICAL)
        let limit = min(max(params.limit, 0), Int(Int32.max) - 1)

        let (conditions, bindings) = try buildSearchConditions(params)

        let sortDirection = params.sort == .asc ? "ASC" : "DESC"

        let sql = """
            SELECT m.ROWID, s.subject, a.address, a.comment,
                   m.date_received, m.read, m.flagged, mb.url
            FROM messages m
            JOIN subjects s ON m.subject = s.ROWID
            JOIN addresses a ON m.sender = a.ROWID
            JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.date_received \(sortDirection), m.ROWID \(sortDirection)
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MailSQLiteError.queryFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        // Bind parameters
        var idx: Int32 = 1
        for binding in bindings {
            sqlite3_bind_text(stmt, idx, binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            idx += 1
        }
        // Fetch one extra row to detect truncation definitively (#204).
        let fetchLimit = limit + 1
        sqlite3_bind_int(stmt, idx, Int32(fetchLimit))

        // Execute and collect results
        var results: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = Int(sqlite3_column_int64(stmt, 0))
            let subject = columnText(stmt, 1)
            let senderAddr = columnText(stmt, 2)
            let senderName = columnText(stmt, 3)
            let dateReceived = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
            let isRead = sqlite3_column_int(stmt, 5) != 0
            let isFlagged = sqlite3_column_int(stmt, 6) != 0
            let mailboxUrl = columnText(stmt, 7)

            let parsed = MailboxURL.decode(mailboxUrl)
            let acctName = parsed.map { accountName(for: $0.accountUUID) } ?? ""
            let acctId = parsed?.accountUUID  // #101: surface UUID for disambiguation
            let mbPath = parsed?.mailboxPath ?? mailboxUrl

            // Fetch To recipients for this message
            let toAddrs = fetchRecipients(messageId: rowId, type: 0)

            results.append(SearchResult(
                id: rowId,
                subject: subject,
                senderAddress: senderAddr,
                senderName: senderName,
                dateReceived: dateReceived,
                accountName: acctName,
                accountId: acctId,
                mailboxPath: mbPath,
                isRead: isRead,
                isFlagged: isFlagged,
                toRecipients: toAddrs
            ))
        }

        let truncated = results.count > limit
        return (Array(results.prefix(limit)), truncated)
    }

    /// Backward-compatible array form — returns at most `limit` results without
    /// the truncation flag. Prefer `searchPage` when truncation matters (#204).
    public func search(_ params: SearchParameters) throws -> [SearchResult] {
        try searchPage(params).results
    }

    /// #177: triage (`summary`) projection — `id/subject/sender/date/mailbox`
    /// only, performing **no** per-row recipient subquery (the cost `full` pays).
    /// With `dedup`, collapses mailbox-duplicate rows via `GROUP BY` + `MIN(ROWID)`
    /// (SQLite's single-aggregate bare-column rule returns each group's
    /// `MIN(ROWID)`-row values). Same definitive `limit + 1` truncation as
    /// `searchPage`/`searchIds`. Returns `SearchResult`s with empty `toRecipients`
    /// (the summary shape drops recipients); the caller emits the 5 triage fields.
    public func searchSummaryPage(_ params: SearchParameters, dedup: Bool = false) throws -> (results: [SearchResult], truncated: Bool) {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        let limit = min(max(params.limit, 0), Int(Int32.max) - 1)
        let (conditions, bindings) = try buildSearchConditions(params)
        let sortDirection = params.sort == .asc ? "ASC" : "DESC"
        let whereClause = conditions.joined(separator: " AND ")

        let rowIdExpr = dedup ? "MIN(m.ROWID)" : "m.ROWID"
        let groupBy = dedup ? "GROUP BY s.subject, a.address, m.date_received" : ""
        let sql = """
            SELECT \(rowIdExpr), s.subject, a.address, a.comment, m.date_received, mb.url
            FROM messages m
            JOIN subjects s ON m.subject = s.ROWID
            JOIN addresses a ON m.sender = a.ROWID
            JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE \(whereClause)
            \(groupBy)
            ORDER BY m.date_received \(sortDirection), \(rowIdExpr) \(sortDirection)
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for binding in bindings {
            sqlite3_bind_text(stmt, idx, binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            idx += 1
        }
        let fetchLimit = limit + 1
        sqlite3_bind_int(stmt, idx, Int32(fetchLimit))

        var results: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = Int(sqlite3_column_int64(stmt, 0))
            let subject = columnText(stmt, 1)
            let senderAddr = columnText(stmt, 2)
            let senderName = columnText(stmt, 3)
            let dateReceived = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
            let mailboxUrl = columnText(stmt, 5)

            let parsed = MailboxURL.decode(mailboxUrl)
            let acctName = parsed.map { accountName(for: $0.accountUUID) } ?? ""
            let acctId = parsed?.accountUUID
            let mbPath = parsed?.mailboxPath ?? mailboxUrl

            results.append(SearchResult(
                id: rowId, subject: subject, senderAddress: senderAddr, senderName: senderName,
                dateReceived: dateReceived, accountName: acctName, accountId: acctId,
                mailboxPath: mbPath, isRead: false, isFlagged: false, toRecipients: []
            ))
        }

        let truncated = results.count > limit
        return (Array(results.prefix(limit)), truncated)
    }

    /// Build the shared WHERE conditions + positional bindings for a search query.
    /// Used by `searchPage` (full rows), `searchIds` (rowId projection), and
    /// `searchCount`. Defining the field / date / account / mailbox semantics
    /// here once guarantees every projection matches identically (#208).
    /// #317 — pure decode-side mailbox path matcher. Preserves the pre-existing
    /// two-pattern LIKE semantics (the named mailbox itself — by full path or
    /// leaf/suffix-at-boundary — plus its descendants) with EXACT string
    /// comparison instead of a wildcard pattern, so nothing the caller passes
    /// can act as query syntax.
    static func mailboxPathMatches(query: String, decodedPath p: String) -> Bool {
        p == query                        // full path, exact (the round-trip case)
            || p.hasSuffix("/" + query)   // leaf / suffix at a path boundary
            || p.hasPrefix(query + "/")   // descendant of a full-path query
            || p.contains("/" + query + "/") // descendant of a suffix-named mailbox
    }

    /// #317 — resolve mailbox ROWIDs by decoding each row's URL with the SAME
    /// `MailboxURL.decode` that produces the `mailbox` strings in search
    /// results, then comparing paths in Swift. The old encode-then-LIKE put
    /// percent-encoded bytes into a LIKE pattern with no ESCAPE clause, so
    /// every `%XX` — and any literal `%`/`_` in a mailbox name — acted as a
    /// wildcard: `Se_t` matched `Sent`, and cross-account byte coincidences
    /// over-matched. Decode-side equality makes "the tool accepts its own
    /// output" true by construction. The mailboxes table is tens of rows, so
    /// the extra pass is noise.
    private func mailboxRowIds(matchingPath query: String, accountUUID: String? = nil) throws -> [Int64] {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ROWID, url FROM mailboxes", -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlC = sqlite3_column_text(stmt, 1) else { continue }
            let url = String(cString: urlC)
            if let uuid = accountUUID, !url.contains("://\(uuid)/") { continue }
            guard let decoded = MailboxURL.decode(url) else { continue }
            if Self.mailboxPathMatches(query: query, decodedPath: decoded.mailboxPath) {
                ids.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return ids
    }

    /// `col IN (…)` from resolver output; a never-true condition when the name
    /// resolved to no mailbox (honest empty result, matching prior behavior).
    /// ROWIDs come from sqlite3_column_int64, so interpolation is inert.
    private static func rowIdInCondition(_ column: String, _ ids: [Int64]) -> String {
        ids.isEmpty ? "0 = 1" : "\(column) IN (\(ids.map(String.init).joined(separator: ",")))"
    }

    private func buildSearchConditions(_ params: SearchParameters) throws -> (conditions: [String], bindings: [String]) {
        var conditions: [String] = ["m.deleted = 0"]
        var bindings: [String] = []
        let likeQuery = "%\(params.query)%"

        // Field-specific conditions
        switch params.field {
        case .subject:
            conditions.append("s.subject LIKE ?")
            bindings.append(likeQuery)

        case .sender:
            conditions.append("(a.address LIKE ? OR a.comment LIKE ?)")
            bindings.append(likeQuery)
            bindings.append(likeQuery)

        case .recipient:
            conditions.append("""
                EXISTS (SELECT 1 FROM recipients r \
                JOIN addresses ra ON r.address = ra.ROWID \
                WHERE r.message = m.ROWID \
                AND (ra.address LIKE ? OR ra.comment LIKE ?))
                """)
            bindings.append(likeQuery)
            bindings.append(likeQuery)

        case .any:
            conditions.append("""
                (s.subject LIKE ? \
                OR a.address LIKE ? OR a.comment LIKE ? \
                OR EXISTS (SELECT 1 FROM recipients r \
                JOIN addresses ra ON r.address = ra.ROWID \
                WHERE r.message = m.ROWID \
                AND (ra.address LIKE ? OR ra.comment LIKE ?)))
                """)
            bindings.append(likeQuery) // subject
            bindings.append(likeQuery) // sender address
            bindings.append(likeQuery) // sender comment
            bindings.append(likeQuery) // recipient address
            bindings.append(likeQuery) // recipient comment
        }

        // Date range filtering
        if let dateFrom = params.dateFrom {
            conditions.append("m.date_received >= ?")
            bindings.append(String(Int(dateFrom.timeIntervalSince1970)))
        }
        if let dateTo = params.dateTo {
            conditions.append("m.date_received <= ?")
            bindings.append(String(Int(dateTo.timeIntervalSince1970)))
        }

        // Account filter via mailbox URL (uuid is internal plist data — no %/_)
        var accountUUID: String?
        if let accountName = params.accountName {
            if let uuid = accountUUIDs(forName: accountName).first {
                accountUUID = uuid
                conditions.append("mb.url LIKE ?")
                bindings.append("%://\(uuid)/%")
            }
        }

        // Mailbox filter (#317): decode-side ROWID resolution, not encode+LIKE.
        if let mailbox = params.mailbox {
            let ids = try mailboxRowIds(matchingPath: mailbox, accountUUID: accountUUID)
            conditions.append(Self.rowIdInCondition("m.mailbox", ids))
        }

        return (conditions, bindings)
    }

    /// Light id-only projection (#208). Selects `ROWID` only and **never**
    /// performs the per-row recipient subquery that `searchPage` uses to fill
    /// `to` — so a bulk caller collecting rowIds for `export_emails_markdown`
    /// gets an orders-of-magnitude smaller payload and avoids N+1 queries.
    /// Honors the #204 `limit + 1` definitive truncation. When `dedup` is true,
    /// collapses mailbox-duplicate copies (same subject / sender / date_received)
    /// to one representative `MIN(ROWID)` server-side via `GROUP BY`.
    public func searchIds(_ params: SearchParameters, dedup: Bool = false) throws -> (ids: [Int], truncated: Bool) {
        guard let db = db else {
            throw MailSQLiteError.queryFailed("Database not open")
        }

        // Same clamp as searchPage: negative → 0 (crash-free), cap below Int32.max-1 (#204).
        let limit = min(max(params.limit, 0), Int(Int32.max) - 1)
        let (conditions, bindings) = try buildSearchConditions(params)
        let sortDirection = params.sort == .asc ? "ASC" : "DESC"
        let whereClause = conditions.joined(separator: " AND ")

        let sql: String
        if dedup {
            sql = """
                SELECT MIN(m.ROWID)
                FROM messages m
                JOIN subjects s ON m.subject = s.ROWID
                JOIN addresses a ON m.sender = a.ROWID
                JOIN mailboxes mb ON m.mailbox = mb.ROWID
                WHERE \(whereClause)
                GROUP BY s.subject, a.address, m.date_received
                ORDER BY m.date_received \(sortDirection), MIN(m.ROWID) \(sortDirection)
                LIMIT ?
                """
        } else {
            sql = """
                SELECT m.ROWID
                FROM messages m
                JOIN subjects s ON m.subject = s.ROWID
                JOIN addresses a ON m.sender = a.ROWID
                JOIN mailboxes mb ON m.mailbox = mb.ROWID
                WHERE \(whereClause)
                ORDER BY m.date_received \(sortDirection), m.ROWID \(sortDirection)
                LIMIT ?
                """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MailSQLiteError.queryFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for binding in bindings {
            sqlite3_bind_text(stmt, idx, binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            idx += 1
        }
        // Fetch one extra to detect truncation definitively (#204).
        let fetchLimit = limit + 1
        sqlite3_bind_int(stmt, idx, Int32(fetchLimit))

        var ids: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int64(stmt, 0)))
        }

        let truncated = ids.count > limit
        return (Array(ids.prefix(limit)), truncated)
    }

    /// Count-only projection (#208). Returns the total number of matches,
    /// **ignoring** `limit`, for cheap backlog scoping. When `dedup` is true,
    /// counts deduplicated logical emails (same subject / sender / date_received)
    /// rather than raw mailbox-duplicated rows.
    public func searchCount(_ params: SearchParameters, dedup: Bool = false) throws -> Int {
        guard let db = db else {
            throw MailSQLiteError.queryFailed("Database not open")
        }

        let (conditions, bindings) = try buildSearchConditions(params)
        let whereClause = conditions.joined(separator: " AND ")

        let sql: String
        if dedup {
            sql = """
                SELECT COUNT(*) FROM (
                    SELECT 1
                    FROM messages m
                    JOIN subjects s ON m.subject = s.ROWID
                    JOIN addresses a ON m.sender = a.ROWID
                    JOIN mailboxes mb ON m.mailbox = mb.ROWID
                    WHERE \(whereClause)
                    GROUP BY s.subject, a.address, m.date_received
                )
                """
        } else {
            sql = """
                SELECT COUNT(*)
                FROM messages m
                JOIN subjects s ON m.subject = s.ROWID
                JOIN addresses a ON m.sender = a.ROWID
                JOIN mailboxes mb ON m.mailbox = mb.ROWID
                WHERE \(whereClause)
                """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MailSQLiteError.queryFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for binding in bindings {
            sqlite3_bind_text(stmt, idx, binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            idx += 1
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Private Helpers

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    private func fetchRecipients(messageId: Int, type: Int) -> [String] {
        guard let db = db else { return [] }
        let sql = """
            SELECT a.address FROM recipients r
            JOIN addresses a ON r.address = a.ROWID
            WHERE r.message = ? AND r.type = ?
            ORDER BY r.position
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(messageId))
        sqlite3_bind_int(stmt, 2, Int32(type))

        var addrs: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            addrs.append(columnText(stmt, 0))
        }
        return addrs
    }
}
