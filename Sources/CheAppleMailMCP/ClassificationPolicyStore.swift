import Darwin
import Foundation

struct ClassificationPolicyEnvelope: Codable, Equatable, Sendable {
    var policy: ClassificationPolicy
    var approvals: [ClassificationApproval]
    static let empty = ClassificationPolicyEnvelope(policy: .empty, approvals: [])

    /// Plan freshness includes revocations, not just the matching conditions.
    func fingerprint() throws -> String {
        classificationDigest(try classificationCanonicalData(self))
    }
}

struct ClassificationAuditEvent: Codable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case started, moved, refused
        case outcomeUnknown = "outcome_unknown"
    }
    var timestamp: String
    var planID: String
    var itemID: String
    var messageIDDigest: String
    var ruleIDs: [String]
    var category: String
    var outcome: Outcome
    var accountID: String? = nil
    var sourceMailbox: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case timestamp, category, outcome
        case planID = "plan_id", itemID = "item_id", messageIDDigest = "message_id_digest"
        case ruleIDs = "rule_ids", accountID = "account_id", sourceMailbox = "source_mailbox"
    }
}

/// Fixed production namespace; tests inject an isolated directory. No policy
/// is discovered in arbitrary workspaces, and no mail body/subject is accepted
/// by the audit event type. File operations use an anchored directory fd.
struct ClassificationPolicyStore: Sendable {
    private static let trustedHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
    static let defaultDirectory = trustedHome
        .appendingPathComponent(".claude/.mail", isDirectory: true)
    let directory: URL
    private let policyName = "classification-policy.json"
    private let auditName = "classification-audit.jsonl"
    private let maximumPolicyBytes = 8 * 1024 * 1024

    init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    func load() throws -> ClassificationPolicyEnvelope {
        guard let fd = try openDirectory(create: false) else { return .empty }
        defer { close(fd) }
        return try locked(fd) { try loadPolicy(fd) }
    }

    func configure(_ input: ClassificationPolicy, approving: [String] = [],
                   revoking: [String] = [], confirmed: Bool = false,
                   now: Date = Date()) throws -> ClassificationPolicyEnvelope {
        let policy = try input.validated()
        guard Set(approving).count == approving.count, Set(revoking).count == revoking.count,
              Set(approving).isDisjoint(with: Set(revoking)), approving.isEmpty || confirmed else {
            throw ClassificationError.invalidPolicy("approval requires explicit confirmation and unique, disjoint rule ids")
        }
        let byID = Dictionary(uniqueKeysWithValues: policy.rules.map { ($0.id, $0) })
        for id in approving {
            guard let rule = byID[id], rule.enabled, rule.action == .trash else {
                throw ClassificationError.invalidPolicy("only existing enabled trash rules can be approved")
            }
        }
        guard let fd = try openDirectory(create: true) else {
            throw ClassificationError.storage("directory unavailable")
        }
        defer { close(fd) }
        return try locked(fd) {
            let old = try loadPolicy(fd)
            let known = Set(old.policy.rules.map(\.id)).union(byID.keys)
            guard Set(revoking).isSubset(of: known) else {
                throw ClassificationError.invalidPolicy("cannot revoke an unknown rule")
            }
            var approvals: [ClassificationApproval] = []
            for approval in old.approvals {
                guard !revoking.contains(approval.ruleID), !approving.contains(approval.ruleID),
                      let rule = byID[approval.ruleID], rule.enabled, rule.action == .trash,
                      approval.fingerprint == (try rule.fingerprint()) else { continue }
                approvals.append(approval)
            }
            for id in approving {
                approvals.append(.init(ruleID: id, fingerprint: try byID[id]!.fingerprint(),
                                       approvedAt: ISO8601DateFormatter().string(from: now)))
            }
            approvals.sort { $0.ruleID < $1.ruleID }
            let result = ClassificationPolicyEnvelope(policy: policy, approvals: approvals)
            let data = try classificationCanonicalData(result)
            guard data.count <= maximumPolicyBytes else {
                throw ClassificationError.invalidPolicy("encoded policy exceeds 8 MiB")
            }
            try atomicWrite(data, name: policyName, directoryFD: fd)
            return result
        }
    }

    func appendAudit(_ event: ClassificationAuditEvent) throws {
        func validID(_ value: String) -> Bool {
            value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
                && !value.contains(where: { $0.isWhitespace })
        }
        guard validID(event.category), event.ruleIDs.count <= 200, event.ruleIDs.allSatisfy(validID),
              ISO8601DateFormatter().date(from: event.timestamp) != nil,
              UUID(uuidString: event.planID) != nil, Int(event.itemID).map({ $0 > 0 }) == true,
              event.messageIDDigest.utf8.count == 64,
              event.messageIDDigest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw ClassificationError.storage("invalid audit identifiers")
        }
        var data = try classificationCanonicalData(event)
        guard data.count <= 64 * 1024 else { throw ClassificationError.storage("audit record too large") }
        data.append(0x0a)
        guard let fd = try openDirectory(create: true) else { throw ClassificationError.storage("directory unavailable") }
        defer { close(fd) }
        try locked(fd) {
            let file = openat(fd, auditName, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard file >= 0 else { throw posixFailure("open audit") }
            defer { close(file) }
            let info = try validateFile(file)
            if info.st_size > 0 {
                var tail: UInt8 = 0
                guard pread(file, &tail, 1, info.st_size - 1) == 1, tail == 0x0a else {
                    throw ClassificationError.storage("audit has an incomplete final record; inspect before further actions")
                }
            }
            try writeAll(data, to: file)
            guard fsync(file) == 0, fsync(fd) == 0 else { throw posixFailure("persist audit") }
        }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directory.isFileURL else { throw ClassificationError.storage("directory must be a file URL") }
        // Foundation can shorten an existing /private/var path back to the
        // /var symlink. Preserve the supplied path during no-follow traversal.
        let path = directory.path
        let allComponents = path.split(separator: "/").map { String($0) }
        guard !allComponents.contains("."), !allComponents.contains("..") else {
            throw ClassificationError.storage("directory must not contain dot traversal")
        }
        let trustedHomePath = Self.trustedHome.path
        let withinHome = path == trustedHomePath || path.hasPrefix(trustedHomePath + "/")
        let anchor = withinHome ? trustedHomePath : "/"
        let components: [String]
        if withinHome {
            components = String(path.dropFirst(trustedHomePath.count)).split(separator: "/").map { String($0) }
        } else {
            components = allComponents
        }
        var fd = open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixFailure("open trusted directory anchor") }
        do {
            for (index, component) in components.enumerated() {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next < 0 && errno == ENOENT {
                    if !create { close(fd); return nil }
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
                        throw posixFailure("create classification directory")
                    }
                    guard fsync(fd) == 0 else { throw posixFailure("persist classification directory entry") }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                guard next >= 0 else { throw posixFailure("open classification directory component \(component)") }
                if withinHome || index == components.count - 1 {
                    do { try validateDirectory(next) }
                    catch { close(next); throw error }
                }
                close(fd)
                fd = next
            }
            try validateDirectory(fd)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw ClassificationError.storage("directory must be owned by this user and not writable by others")
        }
    }

    private func locked<T>(_ directoryFD: Int32, _ operation: () throws -> T) throws -> T {
        let fd = openat(directoryFD, ".classification.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw posixFailure("open classification lock") }
        defer { close(fd) }
        _ = try validateFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw ClassificationError.storage("policy/audit store is busy; retry later")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }

    private func validateFile(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            throw ClassificationError.storage("storage file must be a private, singly-linked regular file owned by this user")
        }
        return info
    }

    private func loadPolicy(_ directoryFD: Int32) throws -> ClassificationPolicyEnvelope {
        let file = openat(directoryFD, policyName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if file < 0 {
            if errno == ENOENT { return .empty }
            throw posixFailure("open classification policy")
        }
        defer { close(file) }
        let info = try validateFile(file)
        guard info.st_size >= 0, info.st_size <= maximumPolicyBytes else {
            throw ClassificationError.storage("policy exceeds 8 MiB")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixFailure("read classification policy")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumPolicyBytes else { throw ClassificationError.storage("policy grew beyond 8 MiB") }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["policy", "approvals"], let rawPolicy = object["policy"],
              let rawApprovals = object["approvals"] as? [[String: Any]] else {
            throw ClassificationError.storage("invalid policy envelope")
        }
        let policy = try ClassificationPolicy.decode(JSONSerialization.data(withJSONObject: rawPolicy))
        var ids: Set<String> = []
        for item in rawApprovals {
            guard Set(item.keys) == ["rule_id", "fingerprint", "approved_at"],
                  let id = item["rule_id"] as? String, ids.insert(id).inserted,
                  let hash = item["fingerprint"] as? String,
                  hash.utf8.count == 64,
                  hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                throw ClassificationError.storage("invalid or duplicate approval record")
            }
        }
        let approvals = try JSONDecoder().decode([ClassificationApproval].self,
                                                from: JSONSerialization.data(withJSONObject: rawApprovals))
        return .init(policy: policy, approvals: approvals)
    }

    private func atomicWrite(_ data: Data, name: String, directoryFD: Int32) throws {
        let temporary = ".classification-\(UUID().uuidString).tmp"
        let file = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw posixFailure("create policy temporary") }
        defer { close(file); _ = unlinkat(directoryFD, temporary, 0) }
        try writeAll(data, to: file)
        guard fsync(file) == 0 else { throw posixFailure("persist policy temporary") }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw posixFailure("replace policy") }
        guard fsync(directoryFD) == 0 else { throw posixFailure("persist policy directory") }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixFailure("write classification data")
                }
                guard count > 0 else { throw ClassificationError.storage("short write") }
                offset += count
            }
        }
    }

    private func posixFailure(_ operation: String) -> ClassificationError {
        .storage("\(operation) failed (errno \(errno))")
    }
}
