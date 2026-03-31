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

    /// Base path for mail storage (account directories).
    public static var mailStoragePath: String {
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
    ///   - accountMapping: UUID → account name mapping. Pass an empty dictionary
    ///     to use UUIDs as fallback names. Typically built from AppleScript at startup.
    /// - Throws: `MailSQLiteError.databaseNotAccessible` if the file
    ///   does not exist or cannot be opened (e.g., missing Full Disk Access).
    public init(databasePath: String, accountMapping: [String: String] = [:]) throws {
        self.accountMap = accountMapping

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
