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

    /// `attempting` read back later is `unknown`: nothing shows the message was
    /// not handed over.
    var effectiveState: State { state == .attempting ? .unknown : state }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", accountID = "account_id", state
        case sentCopy = "sent_copy", draftRemoval = "draft_removal"
        case updatedAt = "updated_at", serverReply = "server_reply"
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

    func put(_ record: SendRecord) throws {
        try withLock {
            var file = try read()
            file.entries[record.messageID] = record
            try write(file)
        }
    }

    func remove(_ messageID: String) throws {
        try withLock {
            var file = try read()
            guard file.entries.removeValue(forKey: messageID) != nil else { return }
            try write(file)
        }
    }

    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    private func read() throws -> File {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
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
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockPath = directory.appendingPathComponent(".\(Self.fileName).lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Problem(detail: "its lock cannot be opened (errno \(errno))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Problem(detail: "cannot be locked (errno \(errno))") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
