import Darwin
import Foundation

/// A complete local VIP lookup, never a best-effort list. Unknown data cannot
/// authorize automatic disposition. This snapshot is transient, not Codable.
public struct VIPSenderSnapshot: Sendable {
    private let addresses: Set<String>?
    private let observedAt: Date
    private static let maximumBytes = 1_048_576
    private static let lifetime: TimeInterval = 60

    public static let unavailable = VIPSenderSnapshot(addresses: nil, observedAt: .distantPast)

    public func status(for sender: String, at now: Date = Date()) -> Bool? {
        let age = now.timeIntervalSince(observedAt)
        guard age >= 0, age < Self.lifetime, let addresses,
              let address = Self.canonicalAddress(sender) else { return nil }
        return addresses.contains(address)
    }

    /// Supported sender-record shapes only. Do not search arbitrary plist
    /// strings, drop malformed records, or infer an empty list from an unknown
    /// layout. A future Mail format must fail closed until explicitly supported.
    public static func parse(_ data: Data, observedAt: Date = Date()) -> VIPSenderSnapshot {
        guard data.count <= maximumBytes,
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return .unavailable
        }
        let records: [[String: Any]]
        if let array = raw as? [[String: Any]] {
            records = array
        } else if let root = raw as? [String: Any], let senders = root["Senders"] {
            if let array = senders as? [[String: Any]] { records = array }
            else if let keyed = senders as? [String: [String: Any]] { records = Array(keyed.values) }
            else { return .unavailable }
        } else {
            return .unavailable
        }
        var addresses: Set<String> = []
        for record in records {
            guard let values = record["Addresses"] as? [String], !values.isEmpty else { return .unavailable }
            for value in values {
                guard let address = canonicalAddress(value) else { return .unavailable }
                addresses.insert(address)
            }
        }
        return .init(addresses: addresses, observedAt: observedAt)
    }

    private static func canonicalAddress(_ raw: String) -> String? {
        guard let address = EmailAddress.singleCanonical(raw) else { return nil }
        // singleCanonical preserves quoted local parts and address literals.
        // Those can have equivalent spellings, so string inequality would not
        // establish non-VIP. Keep this disposition proof to ASCII dot-atoms and
        // DNS labels; unsupported forms on EITHER side make the lookup unknown.
        let atom = #"[a-z0-9!#$%&'*+/=?^_`{|}~-]+"#
        let label = #"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"#
        let pattern = "^" + atom + "(?:\\." + atom + ")*@" + label + "(?:\\." + label + ")*$"
        guard address.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return address
    }

    /// Read on every call; never retain the previous success on a failed read.
    /// Freshness dates the observation, not mtime (an old unchanged plist is
    /// still current). A bounded, nonblocking regular-file read also rejects
    /// replacement or modification during the read, including atomic rename.
    public static func read(from url: URL = EnvelopeIndexReader.defaultVIPSendersURL,
                            observedAt: Date = Date()) -> VIPSenderSnapshot {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else { return .unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Int(before.st_size) + 1),
              data.count == before.st_size else { return .unavailable }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
              sameFile(before, after), sameFile(after, path) else { return .unavailable }
        return parse(data, observedAt: observedAt)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
