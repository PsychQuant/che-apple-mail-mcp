import Foundation
import Darwin

/// One draft that direct transport has tried to send (#742), keyed by its
/// Message-ID. It records states and stages only: no subject, recipient or body.
struct SendRecord: Codable, Equatable {
    enum State: String, Codable {
        /// Written before the SMTP transaction starts. Found at the start of a
        /// later call, it means the process died without learning the outcome.
        case attempting
        case submitted
        case unknown
    }

    enum Stage: String, Codable {
        case done
        case pending
        case skipped
    }

    let messageID: String
    let accountID: String
    var state: State
    var sentCopy: Stage
    var draftRemoval: Stage
    var updatedAt: Date
    var serverReply: String?
    /// When the server accepted the message. Set once; later stages change only `updatedAt`.
    var submittedAt: Date? = nil
    /// SHA-256 of the draft's bytes as fetched for the submission. A pending stage
    /// is completed only for a draft with the same bytes.
    var draftDigest: String? = nil
    /// The login and IMAP server the draft was submitted from, as
    /// `address@host:port`. A pending stage is completed only on that server.
    var server: String? = nil
    /// The drafts mailbox the draft was submitted from (#748). A pending removal
    /// is done, or inferred from the draft's absence, only in that mailbox: the
    /// sent copy has the same Message-ID and bytes. Nil in an entry written
    /// before #748, which is resumed as before.
    var draftsMailbox: String? = nil

    /// `attempting` read back later is `unknown`: nothing shows the message was
    /// not handed over.
    var effectiveState: State { state == .attempting ? .unknown : state }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", accountID = "account_id", state
        case sentCopy = "sent_copy", draftRemoval = "draft_removal"
        case updatedAt = "updated_at", serverReply = "server_reply"
        case submittedAt = "submitted_at", draftDigest = "draft_digest", server
        case draftsMailbox = "drafts_mailbox"
    }
}

/// The record of sent drafts: one JSON file in the server's state directory,
/// mode 0600, replaced as a whole through a temporary file and a rename, under
/// an exclusive lock so two server processes do not interleave their writes.
/// A file that exists and cannot be read is an error, never an empty record:
/// reading it as empty would allow a second submission.
struct SendRecordStore {
    static let fileName = "direct-transport-sent.json"
    let directory: URL

    struct Problem: Error, CustomStringConvertible {
        let detail: String
        var description: String { "\(SendRecordStore.fileName): \(detail)" }
    }

    private struct File: Codable {
        var entries: [String: SendRecord]
    }

    func entry(for messageID: String) throws -> SendRecord? {
        try withLock { try read().entries[messageID] }
    }

    /// Writes `record` only when there is no entry for its Message-ID, as one
    /// step under the lock, and returns the entry that was already there
    /// otherwise. Two calls for the same draft cannot both claim it.
    func claim(_ record: SendRecord) throws -> SendRecord? {
        try withLock {
            var file = try read()
            if let existing = file.entries[record.messageID] { return existing }
            file.entries[record.messageID] = record
            try write(file)
            return nil
        }
    }

    /// A change that is visible but not durable counts as made: what a later
    /// call reads is the new record.
    func put(_ record: SendRecord) throws {
        try withLock {
            var file = try read()
            file.entries[record.messageID] = record
            do { try write(file) } catch is NotDurable {}
        }
    }

    enum ForgetResult: Equatable {
        case removed
        case submitted
        case absent
        /// A `send_draft` call holds the submission lock: an `attempting` entry may be live.
        case inProgress
    }

    /// Removes the entry when its state is unknown, as one step under the record
    /// lock, and only while no `send_draft` call holds the submission lock. A
    /// submitted entry is kept.
    func forgetUnknown(_ messageID: String) throws -> ForgetResult {
        guard let submission = try acquireSubmissionLock() else { return .inProgress }
        defer { submission.release() }
        return try withLock {
            var file = try read()
            guard let entry = file.entries[messageID] else { return .absent }
            if entry.effectiveState == .submitted { return .submitted }
            file.entries.removeValue(forKey: messageID)
            do { try write(file) } catch is NotDurable {}
            return .removed
        }
    }

    /// The change was written and is visible, but its directory could not be
    /// synchronised, so it might not survive a system crash.
    struct NotDurable: Error, CustomStringConvertible {
        let errno: Int32
        var description: String { "\(SendRecordStore.fileName) was changed, but its directory could not be synchronised (errno \(errno)); the change may not survive a system crash" }
    }

    struct Busy: Error, CustomStringConvertible {
        var description: String { "another send_draft or append_draft call is running; nothing was submitted. Try again when it has finished" }
    }

    /// Runs `body` holding the submission lock, which one `send_draft` call at a
    /// time holds from its first look at the record to its last write. Throws
    /// `Busy` without waiting when another call holds it. The lock is released
    /// when the process ends, so an entry left `attempting` by a crash can be forgotten.
    func withSubmissionLock<T>(_ body: () async throws -> T) async throws -> T {
        guard let lock = try acquireSubmissionLock() else { throw Busy() }
        defer { lock.release() }
        return try await body()
    }

    private struct SubmissionLock {
        let fd: Int32
        func release() { flock(fd, LOCK_UN); close(fd) }
    }

    /// Nil when another open file description holds it.
    private func acquireSubmissionLock() throws -> SubmissionLock? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(".\(Self.fileName).submission.lock").path
        // O_CLOEXEC: a child process must not inherit, and so keep, the lock.
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem(detail: "its submission lock cannot be opened (errno \(errno))") }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return SubmissionLock(fd: fd) }
        let reason = errno
        close(fd)
        if reason == EWOULDBLOCK { return nil }
        throw Problem(detail: "its submission lock cannot be taken (errno \(reason))")
    }

    func remove(_ messageID: String) throws {
        try withLock {
            var file = try read()
            guard file.entries.removeValue(forKey: messageID) != nil else { return }
            do { try write(file) } catch is NotDurable {}
        }
    }

    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    private func read() throws -> File {
        // A symlink is refused, never followed: a link whose target is gone would
        // read as "no record", and that allows a second submission.
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw Problem(detail: "is a symbolic link; the record must be a plain file")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            guard lstat(url.path, &info) != 0, errno == ENOENT else {
                throw Problem(detail: "cannot be read")
            }
            return File(entries: [:])
        } catch {
            throw Problem(detail: "cannot be read (\(error.localizedDescription))")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(File.self, from: data)
        } catch {
            throw Problem(detail: "is not a record this version can read")
        }
    }

    private func write(_ file: File) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(file)
        let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Problem(detail: "cannot be written (errno \(errno))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw Problem(detail: "cannot be replaced (errno \(errno))")
        }
        // The rename is durable only once the directory is: the claim must survive
        // a crash before the SMTP transaction it guards. The new record is visible
        // already, so a failure here is not "nothing changed".
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw NotDurable(errno: errno) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw NotDurable(errno: errno) }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockPath = directory.appendingPathComponent(".\(Self.fileName).lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem(detail: "its lock cannot be opened (errno \(errno))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Problem(detail: "cannot be locked (errno \(errno))") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
