import Foundation
import SQLite3

/// Read-only interface to Apple Mail's Envelope Index SQLite database.
/// Provides millisecond-level email search by directly querying the index
/// instead of going through AppleScript.
///
/// Thread safety: a reader owns ONE `sqlite3*` and the server shares the reader
/// between all concurrently running request handlers, so the connection is
/// opened `SQLITE_OPEN_FULLMUTEX` (serialized mode: SQLite takes the connection
/// mutex for every API call) and given a busy timeout (#536). "WAL readonly
/// connections support concurrent readers" is true of several connections, not
/// of one connection used by several threads at once: that is undefined
/// behaviour under `NOMUTEX` (observed as crashes in synthetic runs and as a
/// CPU-bound livelock in the field). Every method below prepares, steps and
/// finalizes inside its own call, so serialized mode is sufficient and no
/// actor or lock is needed on top of it for SQLite. The account mapping is
/// separate state that a lookup can replace (#554), so it has its own lock.
public final class EnvelopeIndexReader {

    // Built once during initialization from the schema, which does not change
    // while the reader is open. Mailbox names are data and are read by every
    // query through `che_drafts_folder` (#374 verify).
    private var draftStatusSQL = "NULL"

    // MARK: - Constants

    private static let mailDataVersion = "V10"

    /// How long SQLite waits on a locked database before giving up. Matches
    /// `DraftStoreWriter`'s value; with a serialized connection this is also
    /// the longest one busy wait can hold up the other readers.
    static let busyTimeoutMilliseconds: Int32 = 5000

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

    /// Mapping from account UUID to human-readable account name. Guarded by
    /// `mappingLock`: the server shares one reader between concurrent request
    /// handlers, and a lookup that misses can replace the mapping (#554).
    private var accountMap: [String: String]

    /// Reverse index: display_name → list of UUIDs. Rebuilt whenever
    /// `accountMap` is set. List form (not single value) surfaces
    /// multi-account-same-display-name collisions to callers — see #101.
    /// Guarded by `mappingLock`.
    private var reverseAccountMap: [String: [String]]

    /// Seconds a lookup miss waits after the last read of the mapping source
    /// before it reads it again (#554). A name that never resolves therefore
    /// costs at most one AccountsMap.plist read per interval, not one per call.
    public static let defaultMappingRefreshCooldown: TimeInterval = 5

    /// Where the mapping is re-read from when a lookup misses (#554): an
    /// account added or renamed while the server runs is in AccountsMap.plist
    /// but not in the mapping built at init. `nil` when the caller injected a
    /// fixed mapping without a source, so fixtures never read the user's plist.
    private let mappingSource: (() -> [String: String])?
    /// When the source last changed; compared at most once per cooldown so a
    /// lookup that hits can notice a changed source too (#615). `nil` with no
    /// source, and for a source that has no such date.
    private let mappingStamp: (() -> Date?)?
    private let mappingRefreshCooldown: TimeInterval
    private let clock: () -> TimeInterval
    /// When `mappingSource` was last read; `nil` if it never was.
    private var lastMappingRead: TimeInterval?
    /// The stamp taken just before the held mapping was read.
    private var mappingStampRead: Date?
    /// When the stamp was last compared; bounds the `stat` to once per cooldown.
    private var lastStampCheck: TimeInterval?
    /// Bumped whenever a mapping is installed, so a refresh that read the
    /// source while another install happened does not overwrite the newer one.
    private var mappingGeneration = 0
    private let mappingLock = NSLock()

    // MARK: - Initialization

    /// Open the Envelope Index database in read-only mode.
    ///
    /// - Parameters:
    ///   - databasePath: Path to the Envelope Index SQLite file.
    ///   - accountMapping: UUID → account name mapping. Defaults to reading
    ///     `accountMappingSource`, which defaults to AccountsMap.plist via
    ///     `AccountMapper.buildMapping()` (no AppleScript).
    ///   - accountMappingSource: Re-read when a name or UUID lookup misses, at
    ///     most once per `mappingRefreshCooldown` (#554). Defaults to
    ///     `AccountMapper.buildMapping()` when `accountMapping` is `nil`, and to
    ///     no source (the injected mapping is never replaced) when it is given.
    ///   - accountMappingStamp: When the source last changed, compared at most
    ///     once per `mappingRefreshCooldown` on any lookup (#615). Defaults to
    ///     the plist's modification date when the source is the default one, and
    ///     to none otherwise: a source without a stamp is re-read on misses only.
    ///   - mappingRefreshCooldown: Minimum seconds between two reads of the
    ///     source. When the initial mapping is read from the source (no
    ///     `accountMapping` given), that read starts the cooldown; an injected
    ///     mapping does not, so the first miss reads the source at once.
    ///   - clock: Monotonic seconds, injected for tests.
    /// - Throws: `MailSQLiteError.databaseNotAccessible` if the file
    ///   does not exist or cannot be opened (e.g., missing Full Disk Access).
    public init(databasePath: String,
                accountMapping: [String: String]? = nil,
                accountMappingSource: (() -> [String: String])? = nil,
                accountMappingStamp: (() -> Date?)? = nil,
                mappingRefreshCooldown: TimeInterval = EnvelopeIndexReader.defaultMappingRefreshCooldown,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        // Checked before the account mapping, so an absent path (a test-owned
        // fixture, #329) never reads the user's AccountsMap.plist.
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw MailSQLiteError.databaseNotAccessible(
                FullDiskAccessHelp.guidance(
                    reason: "Database does not exist or is unreadable at \(databasePath)."
                )
            )
        }

        let source: (() -> [String: String])? = accountMappingSource
            ?? (accountMapping == nil ? { AccountMapper.buildMapping() } : nil)
        self.mappingSource = source
        let usesDefaultSource = accountMapping == nil && accountMappingSource == nil
        self.mappingStamp = accountMappingStamp
            ?? (usesDefaultSource ? { AccountMapper.accountsMapModificationDate() } : nil)
        self.mappingRefreshCooldown = mappingRefreshCooldown
        self.clock = clock
        // Taken before the first read, so a change during it shows up at the next check.
        self.mappingStampRead = mappingStamp?()
        self.lastStampCheck = clock()
        let mapping: [String: String]
        if let accountMapping = accountMapping {
            mapping = accountMapping
        } else {
            mapping = source?() ?? [:]
            self.lastMappingRead = clock()
        }
        self.accountMap = mapping
        self.reverseAccountMap = Self.buildReverseMap(from: mapping)

        // FULLMUTEX, not NOMUTEX: this one connection is shared by concurrent
        // request handlers (#536). Merely dropping NOMUTEX would not help: the
        // library default is multi-thread (`sqlite3_threadsafe()` == 2), which
        // also leaves the connection unguarded.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databasePath, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw MailSQLiteError.databaseNotAccessible(
                FullDiskAccessHelp.guidance(reason: "Failed to open database: \(msg).")
            )
        }
        // Wait for a locked database instead of failing at once. With a
        // serialized connection a busy wait also holds the connection mutex, so
        // this value bounds how long one wait can delay the other readers.
        sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds)

        // `sqlite3_open_v2` reads nothing: it succeeds for any file, and for a WAL
        // database it does not touch `-wal` / `-shm` yet. A reader that only
        // "opened" would be handed out as available while every query fails
        // (#537), so prove the connection reads before calling it open.
        var probeStmt: OpaquePointer?
        var probeRC = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &probeStmt, nil)
        if probeRC == SQLITE_OK {
            probeRC = sqlite3_step(probeStmt)
        }
        let probeResult = probeRC
        let probeMessage = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        let probeExtended = db.map { sqlite3_extended_errcode($0) } ?? probeResult
        sqlite3_finalize(probeStmt)
        guard probeResult == SQLITE_ROW || probeResult == SQLITE_DONE else {
            sqlite3_close(db)
            db = nil
            throw MailSQLiteError.databaseNotAccessible(
                FullDiskAccessHelp.guidance(
                    reason: "Failed to read database: \(probeMessage) (SQLite result code \(probeExtended))."
                )
            )
        }
        draftStatusSQL = Self.resolveDraftStatusSQL(db)

    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Connection introspection (tests only)

    /// Whether SQLite guards this connection with its own mutex (serialized
    /// mode). `@testable`-visible only; not part of the public interface.
    var isSerialized: Bool {
        guard let db = db else { return false }
        return sqlite3_db_mutex(db) != nil
    }

    /// The busy timeout SQLite currently applies to this connection, in
    /// milliseconds (`PRAGMA busy_timeout`). `@testable`-visible only.
    var busyTimeoutMilliseconds: Int32 {
        guard let db = db else { return -1 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA busy_timeout", -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(stmt, 0)
    }

    private static func messageColumns(_ db: OpaquePointer?) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(messages)", -1, &statement, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Cannot inspect messages columns: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name).lowercased()) }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw MailSQLiteError.queryFailed("Message schema inspection failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return columns
    }

    /// The draft-status expression for this connection, or NULL when the schema
    /// cannot be inspected or the folder function cannot be registered: draft
    /// status is then unknown, and the rest of the reader still works (#374 verify).
    static func resolveDraftStatusSQL(_ db: OpaquePointer?) -> String {
        do {
            let columns = try messageColumns(db)
            try registerDraftsFolderFunction(db)
            return draftStatusExpression(columns: columns)
        } catch {
            // The throwing overload: a closed stderr must not abort the server (#346).
            try? FileHandle.standardError.write(contentsOf: Data(
                "EnvelopeIndexReader: draft status unavailable (\(error.localizedDescription))\n".utf8))
            return "NULL"
        }
    }

    /// Folder names that mean "drafts" in Mail's common localizations, compared
    /// case- and normalization-insensitively. A folder with one of these names
    /// never makes a message a draft; it only keeps a message in it, or a copy
    /// of one, from being reported as a known non-draft (#374 verify).
    static let draftsFolderNames: Set<String> = Set([
        "Drafts", "Draft", "草稿", "草稿箱", "草稿夾", "下書き", "임시 보관함", "Brouillons", "Entwürfe",
        "Borradores", "Bozze", "Rascunhos", "Concepten", "Utkast", "Kladder", "Luonnokset", "Черновики",
        "Kopie robocze", "Wersje robocze", "임시보관함", "Taslaklar",
    ].map(foldName))

    static func foldName(_ name: String) -> String {
        name.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// Whether a mailbox URL's last component is a drafts-folder name.
    static func isDraftsFolderURL(_ url: String) -> Bool {
        let leaf = url.split(separator: "/").last.map(String.init) ?? ""
        return draftsFolderNames.contains(foldName(leaf.removingPercentEncoding ?? leaf))
    }

    static let draftsFolderFunction = "che_drafts_folder"

    /// `che_drafts_folder(url)` on this connection: 1 for a drafts-folder name or
    /// a NULL url (the name is unknown), else 0. A function rather than a list of
    /// ids taken at open, so a folder created or renamed later is seen by the next
    /// query (#374 verify).
    static func registerDraftsFolderFunction(_ db: OpaquePointer?) throws {
        let status = sqlite3_create_function_v2(
            db, draftsFolderFunction, 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { context, count, values in
                guard count == 1, let values, let text = sqlite3_value_text(values[0]) else {
                    sqlite3_result_int(context, 1)
                    return
                }
                sqlite3_result_int(context, EnvelopeIndexReader.isDraftsFolderURL(String(cString: text)) ? 1 : 0)
            }, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Cannot register \(draftsFolderFunction): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// One SQL expression for every projection: 1 (draft), 0 (known non-draft)
    /// or NULL (unknown), for the row aliased `m`.
    ///
    /// Draft when the message, or any copy sharing its global message id, has
    /// type 5 or Mail's draft flag (0x40 in `flags`). Known non-draft only when
    /// the type is 0 and every piece of evidence is present and negative: the
    /// flag column and the copy column exist, and the message and each copy have
    /// a type other than 5, a flag value without 0x40, and a mailbox whose name
    /// is known and not a drafts name. Everything else is unknown. The type alone
    /// is not enough: drafts synced from a server or another device are stored
    /// with type 0, often in the account's Drafts folder (#374 verify).
    static func draftStatusExpression(columns: Set<String>) -> String {
        guard columns.contains("type") else { return "NULL" }
        let flags = columns.contains("flags")
        let copies = columns.contains("global_message_id")
        func evidence(_ alias: String) -> String {
            flags ? "(\(alias).type = 5 OR (\(alias).flags & 64) != 0)" : "\(alias).type = 5"
        }
        func sharing(_ condition: String) -> String {
            "EXISTS (SELECT 1 FROM messages c WHERE c.global_message_id = m.global_message_id AND \(condition))"
        }
        let isDraft = copies
            ? "(\(evidence("m")) OR (m.global_message_id IS NOT NULL AND \(sharing(evidence("c")))))"
            : evidence("m")
        // Without the flag or copy columns, no type-0 message can be shown clean.
        guard flags, copies else { return "(CASE WHEN \(isDraft) THEN 1 ELSE NULL END)" }
        func clean(_ alias: String) -> String {
            "(\(alias).type IS NOT NULL AND \(alias).type != 5 AND \(alias).flags IS NOT NULL "
                + "AND (\(alias).flags & 64) = 0 AND EXISTS (SELECT 1 FROM mailboxes f "
                + "WHERE f.ROWID = \(alias).mailbox AND \(draftsFolderFunction)(f.url) = 0))"
        }
        // The message is one of the rows sharing its own global message id.
        let known = "(m.type = 0 AND m.global_message_id IS NOT NULL AND \(clean("m")) "
            + "AND NOT \(sharing("NOT \(clean("c"))")))"
        return "(CASE WHEN \(isDraft) THEN 1 WHEN \(known) THEN 0 ELSE NULL END)"
    }

    private static func draftFlag(_ statement: OpaquePointer?, column: Int32) -> Bool? {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { return nil }
        switch sqlite3_column_int64(statement, column) {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    /// Read a per-message fact, not a mailbox-role inference. Unknown is nil.
    public func messageIsDraft(messageId: Int) throws -> Bool? {
        guard let db else { throw MailSQLiteError.queryFailed("Database not open") }
        let sql = "SELECT \(draftStatusSQL) FROM messages m WHERE m.ROWID = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Draft status query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(messageId))
        guard try stepFirstRow(statement, "Draft status query") else {
            throw MailSQLiteError.queryFailed("Draft status unavailable for message \(messageId)")
        }
        return Self.draftFlag(statement, column: 0)
    }

    // MARK: - Account Mapping

    /// Resolve an account UUID to a human-readable name.
    /// Falls back to the UUID itself if no mapping exists. A miss re-reads the
    /// mapping source once (subject to the cooldown) before falling back (#554).
    public func accountName(for uuid: String) -> String {
        refreshMappingIfSourceChanged()
        if let name = withMappingLock({ accountMap[uuid] }) { return name }
        refreshMappingAfterMiss()
        return withMappingLock { accountMap[uuid] } ?? uuid
    }

    /// Update the account mapping (e.g., after querying AppleScript).
    public func updateAccountMapping(_ mapping: [String: String]) {
        withMappingLock {
            accountMap = mapping
            reverseAccountMap = Self.buildReverseMap(from: mapping)
            mappingGeneration += 1
        }
    }

    private func withMappingLock<T>(_ body: () -> T) -> T {
        mappingLock.lock()
        defer { mappingLock.unlock() }
        return body()
    }

    /// Re-read the mapping after a lookup missed (#554).
    ///
    /// The cooldown is checked and claimed under the lock, so concurrent misses
    /// cause one read per interval; a miss that arrives while that read runs
    /// sees the mapping it had. The source itself is read outside the lock: a
    /// source that calls back into the reader cannot deadlock, and lookups that
    /// hit do not wait for the plist read. A read is installed only if no other
    /// mapping was installed meanwhile. An empty result is what
    /// `AccountMapper.buildMapping()` returns when the plist cannot be read, so
    /// it keeps the mapping already known instead of forgetting every account.
    private func refreshMappingAfterMiss() {
        guard mappingSource != nil else { return }
        let claimed: Int? = withMappingLock {
            let now = clock()
            if let last = lastMappingRead, now - last < mappingRefreshCooldown { return nil }
            lastMappingRead = now
            return mappingGeneration
        }
        guard let generation = claimed else { return }
        readAndInstallMapping(generation: generation, stamp: mappingStamp?())
    }

    /// Re-read the mapping when its source changed since it was read (#615), so
    /// a lookup that hits does not keep an answer the source no longer gives.
    /// Claimed under the lock, so per-row lookups cost one `stat` per cooldown.
    private func refreshMappingIfSourceChanged() {
        guard let mappingStamp else { return }
        let due: Bool = withMappingLock {
            let now = clock()
            if let last = lastStampCheck, now - last < mappingRefreshCooldown { return false }
            lastStampCheck = now
            return true
        }
        guard due, let stamp = mappingStamp() else { return }
        let generation: Int? = withMappingLock {
            guard stamp != mappingStampRead else { return nil }
            lastMappingRead = clock()
            return mappingGeneration
        }
        guard let generation else { return }
        readAndInstallMapping(generation: generation, stamp: stamp)
    }

    /// The stamp was taken before this read and is recorded only with a good
    /// mapping, so a read that failed or raced a change is tried again.
    private func readAndInstallMapping(generation: Int, stamp: Date?) {
        guard let source = mappingSource else { return }
        let fresh = source()
        guard !fresh.isEmpty else { return }
        withMappingLock {
            guard mappingGeneration == generation else { return }
            accountMap = fresh
            reverseAccountMap = Self.buildReverseMap(from: fresh)
            mappingStampRead = stamp
            mappingGeneration += 1
        }
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
    ///
    /// A miss re-reads the mapping source once (subject to the cooldown), so an
    /// account added or renamed while the server runs resolves without a
    /// restart (#554).
    public func accountUUIDs(forName name: String) -> [String] {
        refreshMappingIfSourceChanged()
        if let uuids = withMappingLock({ reverseAccountMap[name] }), !uuids.isEmpty { return uuids }
        refreshMappingAfterMiss()
        return withMappingLock { reverseAccountMap[name] } ?? []
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
        try forEachRow(stmt, "Mailbox list") {
            let url = columnText(stmt, 0)
            let totalCount = Int(sqlite3_column_int(stmt, 1))
            let unreadCount = Int(sqlite3_column_int(stmt, 2))

            guard let parsed = MailboxURL.decode(url) else { return }
            let acctName = self.accountName(for: parsed.accountUUID)

            results.append([
                "name": parsed.mailboxPath,
                // #345 verify: `name` is the LOSSY single-pass decode, in which
                // a mailbox literally named `R&D/Sent` is indistinguishable
                // from the hierarchy R&D → Sent. Anything reasoning about
                // hierarchy must use these (#344).
                "path_components": parsed.pathComponents,
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
            SELECT m.ROWID, s.subject, a.address, a.comment, m.date_received, \(draftStatusSQL)
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
        try forEachRow(stmt, "Email list") {
            let rowId = Int(sqlite3_column_int64(stmt, 0))
            let subject = columnText(stmt, 1)
            let senderAddr = columnText(stmt, 2)
            let senderName = columnText(stmt, 3)
            let sender = senderName.isEmpty ? senderAddr : "\(senderName) <\(senderAddr)>"
            results.append([
                "id": String(rowId),
                "subject": subject,
                "sender": sender,
                "is_draft": Self.draftFlag(stmt, column: 5).map { $0 as Any } ?? NSNull()
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

        if try stepFirstRow(stmt, "Unread count") {
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
        try forEachRow(stmt, "Attachment list") {
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
                   m.conversation_id, s.subject, a.address, mb.url, \(draftStatusSQL)
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

        guard try stepFirstRow(stmt, "Metadata query") else {
            throw MailSQLiteError.queryFailed("Message \(messageId) not found")
        }

        let dateReceived = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
        return [
            "is_draft": Self.draftFlag(stmt, column: 9).map { $0 as Any } ?? NSNull(),
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
        if try stepFirstRow(stmt, "Mailbox lookup") {
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
                   m.date_received, m.read, m.flagged, mb.url, \(draftStatusSQL)
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
        try forEachRow(stmt, "Search") {
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
            let toAddrs = try fetchRecipients(messageId: rowId, type: 0)

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
                toRecipients: toAddrs,
                isDraft: Self.draftFlag(stmt, column: 8)
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

    /// #177: triage (`summary`) projection — `id/subject/sender/date/mailbox/is_draft`
    /// only, performing **no** per-row recipient subquery (the cost `full` pays).
    /// With `dedup`, collapses mailbox-duplicate rows via `GROUP BY` + `MIN(ROWID)`
    /// (SQLite's single-aggregate bare-column rule returns each group's
    /// `MIN(ROWID)`-row values). Same definitive `limit + 1` truncation as
    /// `searchPage`/`searchIds`. Returns `SearchResult`s with empty `toRecipients`
    /// (the summary shape drops recipients); the caller emits the 6 triage fields.
    public func searchSummaryPage(_ params: SearchParameters, dedup: Bool = false) throws -> (results: [SearchResult], truncated: Bool) {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }

        let limit = min(max(params.limit, 0), Int(Int32.max) - 1)
        let (conditions, bindings) = try buildSearchConditions(params)
        let sortDirection = params.sort == .asc ? "ASC" : "DESC"
        let whereClause = conditions.joined(separator: " AND ")

        let rowIdExpr = dedup ? "MIN(m.ROWID)" : "m.ROWID"
        let groupBy = dedup ? "GROUP BY s.subject, a.address, m.date_received" : ""
        let sql = """
            SELECT \(rowIdExpr), s.subject, a.address, a.comment, m.date_received, mb.url, \(draftStatusSQL)
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
        try forEachRow(stmt, "Search") {
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
                mailboxPath: mbPath, isRead: false, isFlagged: false, toRecipients: [],
                isDraft: Self.draftFlag(stmt, column: 6)
            ))
        }

        let truncated = results.count > limit
        return (Array(results.prefix(limit)), truncated)
    }

    /// Build the shared WHERE conditions + positional bindings for a search query.
    /// Used by `searchPage` (full rows), `searchIds` (rowId projection), and
    /// `searchCount`. Defining the field / date / account / mailbox semantics
    /// here once guarantees every projection matches identically (#208).
    /// ASCII-only case-insensitive equality (#344).
    ///
    /// Deliberately **not** a Unicode fold. The only two things here that need
    /// case-insensitivity — RFC 3501's `INBOX` and a hex account UUID — are
    /// both defined over ASCII, and a Unicode fold would widen them in ways
    /// neither spec asks for (a Turkish dotless `ı`, a Kelvin sign).
    static func asciiCaseInsensitiveEqual(_ a: String, _ b: String) -> Bool {
        let x = a.utf8, y = b.utf8
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { asciiLower($0) == asciiLower($1) }
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte  // 'A'...'Z'
    }

    private static func asciiLowercased(_ s: String) -> String {
        String(decoding: s.utf8.map(asciiLower), as: UTF8.self)
    }

    /// Comparison key for one mailbox path component (#344).
    ///
    /// **Strict** is the shipping rule: `INBOX` folds — RFC 3501 §5.1 makes it
    /// the one spec-level case-insensitive mailbox name — and every other
    /// component compares byte-exact. Folding everything would restore the
    /// pre-#317 `LIKE` behavior, but that behavior was accidentally lax rather
    /// than correct: other names are implementation-dependent and typically
    /// case-sensitive, so on such a server `Work` and `work` are two mailboxes
    /// and returning the wrong one's mail is a failure nobody notices. A miss
    /// is visible; a wrong hit is not.
    ///
    /// **Lax** exists only to hunt for a near-miss *after* a strict resolution
    /// came up empty (see `mailboxRowIds`). It never selects rows to return.
    static func mailboxComponentKey(_ component: String, lax: Bool) -> String {
        if lax {
            return asciiLowercased(component.trimmingCharacters(in: .whitespaces))
        }
        return component
    }

    /// Compare one path component against one query component.
    ///
    /// - Parameter atPathRoot: whether the path component sits at index 0.
    ///   **RFC 3501 §5.1's `INBOX` is a mailbox *name*, not a token that may
    ///   appear anywhere in a hierarchy**, so the fold applies only there — at
    ///   the mailbox called INBOX, and at the root of `INBOX/Sub`.
    ///
    ///   The first cut of this fix folded `INBOX` at **every** position, which
    ///   meant a store holding both `Team/INBOX` and `Team/inbox` returned both
    ///   mailboxes' mail for a query naming either one (#344 verify round 1).
    ///   That is precisely the over-match this issue's own diagnosis argued
    ///   against when it rejected blanket folding — reintroduced one level down.
    ///   Note an exact-case query still matches at any depth; only the
    ///   *case-insensitive* privilege is confined to the root.
    ///
    /// Non-root components compare with `==`, which for Swift `String` means
    /// **canonically equivalent**, not byte-identical: an NFC `Café` and an NFD
    /// `Cafe\u{301}` compare equal. That is deliberate — APFS and IMAP servers
    /// both treat those as the same name — but it is not "byte-exact", as an
    /// earlier version of this comment claimed.
    static func mailboxComponentsMatch(path: String, query: String,
                                       atPathRoot: Bool, lax: Bool) -> Bool {
        if lax {
            return mailboxComponentKey(path, lax: true) == mailboxComponentKey(query, lax: true)
        }
        if atPathRoot,
           asciiCaseInsensitiveEqual(path, "INBOX"),
           asciiCaseInsensitiveEqual(query, "INBOX") {
            return true
        }
        return path == query
    }

    /// #317 kept the pre-existing two-pattern LIKE semantics (the named mailbox
    /// itself — by full path or leaf/suffix-at-boundary — plus its descendants)
    /// but moved them to exact string comparison so nothing a caller passes can
    /// act as query syntax.
    ///
    /// #344 moves them again, from the decoded *string* to decoded
    /// *components*. `MailboxURL.mailboxPath` decodes the whole path at once,
    /// so a mailbox literally named `R&D/Sent` (raw `R%26D%2FSent`) is
    /// indistinguishable from the hierarchy `R&D` → `Sent`; reasoning about
    /// `/` in that string meant a name's own slash could pose as a separator
    /// and get pulled in by a `Sent` query. Components are split before
    /// decoding, so that is structurally impossible.
    ///
    /// Three of #317's four clauses collapse into one predicate here: full
    /// path, leaf-at-a-boundary, and descendant-of-either are all *"the query's
    /// components occur as a contiguous run inside the path's components"*,
    /// differing only in where the run sits. Strings had to spell it four ways
    /// because they could not see where a component began.
    static func mailboxPathMatches(query: String, mailbox: MailboxURL, lax: Bool = false) -> Bool {
        guard !query.isEmpty else { return false }

        // The one clause that survives as a whole-string comparison: exact
        // equality against the (lossy) decoded path, so `search_emails` still
        // accepts its own `mailbox` output even for a name containing a
        // literal '/'. Such a name and the equivalent hierarchy are genuinely
        // indistinguishable in that representation — the caller cannot say
        // which they mean, so both resolve rather than one being picked.
        if mailboxComponentKey(mailbox.mailboxPath, lax: lax)
            == mailboxComponentKey(query, lax: lax) {
            return true
        }

        let q = query.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let p = mailbox.pathComponents
        guard !q.isEmpty, q.count <= p.count else { return false }

        // The run is compared position-aware rather than by pre-keying both
        // sides, because whether `INBOX` may fold depends on the component's
        // absolute index in the PATH — which a symmetric key cannot express.
        for start in 0...(p.count - q.count) {
            var matched = true
            for i in 0 ..< q.count
            where !mailboxComponentsMatch(path: p[start + i], query: q[i],
                                          atPathRoot: (start + i) == 0, lax: lax) {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
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
        let (ids, nearMisses) = try resolveMailboxRows(query: query, accountUUID: accountUUID)
        guard ids.isEmpty else { return ids }

        // #344 — before conceding an empty result, look for a near-miss.
        // #317's subject was "a zero you cannot trust": is the mailbox empty,
        // is the name wrong, or is the filter too strict? Naming the candidate
        // answers that WITHOUT loosening what actually matches.
        //
        // "Near" is defined by re-running the SAME matcher under a laxer
        // component key rather than by a separate similarity rule that could
        // drift away from it. Closed list of two classes, and no third is to be
        // inferred by resemblance: (1) ASCII letter case, (2) leading/trailing
        // whitespace. An unrelated name finds no candidate and still returns an
        // honest empty result — this must not turn every legitimately empty
        // filter into an error.
        guard !nearMisses.isEmpty else { return ids }
        throw MailSQLiteError.mailboxNotResolvable(
            name: query,
            candidates: Array(Set(nearMisses)).sorted().prefix(5).map { $0 })
    }

    /// One scan of the mailboxes table producing BOTH the strict matches and
    /// the lax near-misses.
    ///
    /// Deliberately a single statement rather than two passes (#344 verify
    /// round 1): with separate scans, a mailbox arriving between them — Mail
    /// syncs into this database continuously — could be absent from the strict
    /// pass and present in the lax one, producing the absurd
    /// `no mailbox matched 'Work'; did you mean 'Work'?`. One snapshot makes
    /// that unrepresentable, and costs half the work rather than more.
    private func resolveMailboxRows(query: String,
                                    accountUUID: String?) throws -> (ids: [Int64], nearMisses: [String]) {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ROWID, url FROM mailboxes", -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        var nearMisses: [String] = []
        try forEachRow(stmt, "Mailbox lookup") {
            guard let urlC = sqlite3_column_text(stmt, 1) else { return }
            guard let decoded = MailboxURL.decode(String(cString: urlC)) else { return }
            // #344 (B) — a UUID is hex, so its case carries no meaning and
            // folding it cannot over-match onto a different account. Comparing
            // the PARSED authority also beats the old `url.contains("://uuid/")`,
            // which the same text appearing inside a mailbox path could satisfy.
            if let uuid = accountUUID,
               !Self.asciiCaseInsensitiveEqual(decoded.accountUUID, uuid) { return }
            if Self.mailboxPathMatches(query: query, mailbox: decoded, lax: false) {
                ids.append(sqlite3_column_int64(stmt, 0))
            } else if Self.mailboxPathMatches(query: query, mailbox: decoded, lax: true) {
                // Lax-only: a strict match is never also a near-miss, so the
                // suggestion list can never contain the answer itself.
                nearMisses.append(decoded.mailboxPath)
            }
        }
        return (ids, nearMisses)
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
        try forEachRow(stmt, "Search") {
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

        guard try stepFirstRow(stmt, "Search count") else {
            return 0
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Private Helpers

    /// Step `statement` through its result set, calling `body` once per row,
    /// and throw unless SQLite reports the end of the results (#549).
    ///
    /// `while sqlite3_step(stmt) == SQLITE_ROW` treated every other result
    /// (`SQLITE_BUSY` after the busy timeout, `SQLITE_IOERR`, `SQLITE_CORRUPT`,
    /// an interrupt) as "no more rows", so a read that stopped part-way returned
    /// its partial result as if it were complete, with nothing on stderr. The
    /// throw reaches the caller's hybrid fallback instead (r-must-direct-db).
    private func forEachRow(_ statement: OpaquePointer?, _ what: String,
                            _ body: () throws -> Void) throws {
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try body()
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw stepFailure(what, status) }
    }

    /// One-row queries: `true` when there is a row, `false` when the result
    /// set is empty, and a throw for anything else, which used to read as
    /// "no row" (#549).
    private func stepFirstRow(_ statement: OpaquePointer?, _ what: String) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw stepFailure(what, status)
    }

    private func stepFailure(_ what: String, _ status: Int32) -> MailSQLiteError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        let code = db.map { sqlite3_extended_errcode($0) } ?? status
        return .queryFailed("\(what) stopped before the end of its results: \(message) (SQLite result code \(code))")
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    private func fetchRecipients(messageId: Int, type: Int) throws -> [String] {
        guard let db = db else { throw MailSQLiteError.queryFailed("Database not open") }
        let sql = """
            SELECT a.address FROM recipients r
            JOIN addresses a ON r.address = a.ROWID
            WHERE r.message = ? AND r.type = ?
            ORDER BY r.position
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailSQLiteError.queryFailed("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(messageId))
        sqlite3_bind_int(stmt, 2, Int32(type))

        var addrs: [String] = []
        try forEachRow(stmt, "Recipient list") {
            addrs.append(columnText(stmt, 0))
        }
        return addrs
    }
}
