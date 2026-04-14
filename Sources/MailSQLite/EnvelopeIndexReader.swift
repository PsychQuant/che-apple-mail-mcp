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
        self.accountMap = accountMapping ?? AccountMapper.buildMapping()

        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw MailSQLiteError.databaseNotAccessible(
                "Database does not exist at \(databasePath). "
                + "Ensure Full Disk Access is granted to the terminal application "
                + "in System Settings > Privacy & Security > Full Disk Access."
            )
        }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(databasePath, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw MailSQLiteError.databaseNotAccessible(
                "Failed to open database: \(msg). "
                + "Ensure Full Disk Access is granted to the terminal application "
                + "in System Settings > Privacy & Security > Full Disk Access."
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

    /// List all accounts by combining filesystem UUID scan with AccountMapper names.
    public func listAccounts() -> [[String: Any]] {
        let uuids = Self.scanAccountUUIDs()
        return uuids.map { uuid in
            ["name": accountName(for: uuid), "uuid": uuid]
        }
    }

    /// List mailboxes from the SQLite mailboxes table.
    /// - Parameter accountName: Optional account filter (matches against account mapping).
    public func listMailboxes(accountName: String? = nil) throws -> [[String: Any]] {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        var sql = "SELECT url, total_count, unread_count FROM mailboxes"
        var bindings: [String] = []

        if let accountName = accountName {
            if let uuid = accountMap.first(where: { $0.value == accountName })?.key {
                sql += " WHERE url LIKE ?"
                bindings.append("%://\(uuid)/%")
            }
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
    public func listEmails(mailbox: String, accountName: String, limit: Int = 50) throws -> [[String: Any]] {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        var conditions = ["m.deleted = 0"]
        var bindings: [String] = []

        // Account filter
        if let uuid = accountMap.first(where: { $0.value == accountName })?.key {
            conditions.append("mb.url LIKE ?")
            bindings.append("%://\(uuid)/%")
        }

        // Mailbox filter
        let encoded = mailbox.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mailbox
        conditions.append("(mb.url LIKE ? OR mb.url LIKE ?)")
        bindings.append("%/\(encoded)")
        bindings.append("%/\(encoded)/%")

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
        sqlite3_bind_int(stmt, idx, Int32(limit))

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
        return results
    }

    /// Get unread count via SQLite mailboxes table.
    public func getUnreadCount(mailbox: String? = nil, accountName: String? = nil) throws -> Int {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        var sql = "SELECT SUM(unread_count) FROM mailboxes"
        var conditions: [String] = []
        var bindings: [String] = []

        if let accountName = accountName, let uuid = accountMap.first(where: { $0.value == accountName })?.key {
            conditions.append("url LIKE ?")
            bindings.append("%://\(uuid)/%")
        }
        if let mailbox = mailbox {
            let encoded = mailbox.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mailbox
            conditions.append("(url LIKE ? OR url LIKE ?)")
            bindings.append("%/\(encoded)")
            bindings.append("%/\(encoded)/%")
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
    public func search(_ params: SearchParameters) throws -> [SearchResult] {
        guard let db = db else {
            throw MailSQLiteError.queryFailed("Database not open")
        }

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

        // Account filter via mailbox URL
        if let accountName = params.accountName {
            // Find UUID for account name (reverse lookup)
            if let uuid = accountMap.first(where: { $0.value == accountName })?.key {
                conditions.append("mb.url LIKE ?")
                bindings.append("%://\(uuid)/%")
            }
        }

        // Mailbox filter
        if let mailbox = params.mailbox {
            let encoded = mailbox.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mailbox
            conditions.append("(mb.url LIKE ? OR mb.url LIKE ?)")
            bindings.append("%/\(encoded)")
            bindings.append("%/\(encoded)/%")
        }

        let sortDirection = params.sort == .asc ? "ASC" : "DESC"

        let sql = """
            SELECT m.ROWID, s.subject, a.address, a.comment,
                   m.date_received, m.read, m.flagged, mb.url
            FROM messages m
            JOIN subjects s ON m.subject = s.ROWID
            JOIN addresses a ON m.sender = a.ROWID
            JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.date_received \(sortDirection)
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
        sqlite3_bind_int(stmt, idx, Int32(params.limit))

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
                mailboxPath: mbPath,
                isRead: isRead,
                isFlagged: isFlagged,
                toRecipients: toAddrs
            ))
        }

        return results
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
