import Foundation
import Darwin

/// Deliberately distinct from extraction / AppleEvent / unverified-write errors:
/// neither backend fallback nor download retry can recover a destination denial.
enum AttachmentDestinationError: Error, LocalizedError {
    case rejected(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let reason):
            return "save_attachment: destination_rejected: save_path \(reason). "
                + "Use an absolute file path within CHE_MAIL_EXPORT_ALLOWED_ROOTS "
                + "(default: home excluding sensitive paths)."
        case .io(let reason):
            return "save_attachment: destination_write_failed: \(reason). "
                + "Check the save_path directory and write permission."
        }
    }
}

/// A validated, pinned destination, shared by every attachment backend (#402).
/// Canonicalization permits existing aliases only when their final target passes
/// the root/denylist policy. From that point, no directory symlink is followed.
final class AttachmentDestination: @unchecked Sendable {
    let savePath: String
    private let parentFd: Int32
    private let filename: String

    static var configuredRoots: [String] {
        (ProcessInfo.processInfo.environment["CHE_MAIL_EXPORT_ALLOWED_ROOTS"] ?? "")
            .split(separator: ":").map(String.init)
    }

    init(savePath: String, allowedRoots: [String] = AttachmentDestination.configuredRoots,
         beforeValidation: (() throws -> Void)? = nil,
         beforeOpen: (() throws -> Void)? = nil) throws {
        guard savePath.hasPrefix("/"), !savePath.hasSuffix("/"),
              savePath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ ExportEmailsMarkdown.isSafeSegment(String($0)) }) else {
            throw AttachmentDestinationError.rejected("contains an unsafe path component")
        }
        // Foundation's URL path presentation preserves aliases such as /var
        // on macOS. Use realpath for the actual no-follow descriptor walk, then
        // validate that exact target; never reopen the original caller string.
        let canonical = try Self.filesystemPath(savePath)
        try beforeValidation?()
        do {
            let home = try Self.filesystemPath(NSHomeDirectory())
            let roots = try allowedRoots.filter { !$0.isEmpty }.map {
                try Self.filesystemPath(AllowedRootsValidator.canonicalize($0).path)
            }
            try AllowedRootsValidator().validateCanonicalPath(canonical, homePath: home, allowedRoots: roots)
        } catch {
            throw AttachmentDestinationError.rejected("is outside the permitted destination policy (\(error))")
        }
        let components = canonical.dropFirst().split(separator: "/").map(String.init)
        guard components.count > 1, components.allSatisfy(ExportEmailsMarkdown.isSafeSegment) else {
            throw AttachmentDestinationError.rejected("does not name a permitted file")
        }
        // Deterministic validation-to-open race seam; absent in production.
        try beforeOpen?()
        // Start at /, not at a pathname whose ancestors can be swapped to links.
        let rootFd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else { throw AttachmentDestinationError.io("cannot open filesystem root") }
        defer { close(rootFd) }
        let fd: Int32
        do {
            fd = try RaceFreeFileWriter.descendCreatingDirs(
                rootFd: rootFd, components: Array(components.dropLast()))
        } catch {
            throw AttachmentDestinationError.io("cannot open destination directory: \(error)")
        }
        guard faccessat(fd, ".", W_OK, 0) == 0 else {
            close(fd)
            throw AttachmentDestinationError.io("destination directory is not writable")
        }
        var leafInfo = stat()
        if fstatat(fd, components.last!, &leafInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            let kind = leafInfo.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else {
                close(fd)
                throw AttachmentDestinationError.io("destination is not a regular file")
            }
        } else if errno != ENOENT {
            let code = errno
            close(fd)
            throw AttachmentDestinationError.io("cannot inspect destination (errno \(code))")
        }
        self.savePath = savePath
        self.filename = components.last!
        self.parentFd = fd
    }

    private static func filesystemPath(_ path: String) throws -> String {
        var existing = path
        var tail: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                let prefix = String(cString: resolved)
                guard !tail.isEmpty else { return prefix }
                return (prefix == "/" ? "" : prefix) + "/" + tail.reversed().joined(separator: "/")
            }
            guard errno == ENOENT else {
                throw AttachmentDestinationError.io("cannot resolve destination directory (errno \(errno))")
            }
            guard let separator = existing.lastIndex(of: "/"), existing != "/" else {
                throw AttachmentDestinationError.rejected("cannot be resolved")
            }
            tail.append(String(existing[existing.index(after: separator)...]))
            existing = separator == existing.startIndex ? "/" : String(existing[..<separator])
        }
    }

    deinit { close(parentFd) }

    func publish(_ data: Data, allowEmpty: Bool = false) throws -> String {
        guard allowEmpty || !data.isEmpty else {
            throw MailError.attachmentWriteUnverified(path: savePath, problem: .empty)
        }
        do {
            try RaceFreeFileWriter.writeAttachment(dirFd: parentFd, name: filename, data: data)
        } catch {
            throw AttachmentDestinationError.io("cannot publish attachment: \(error)")
        }
        return receipt(Int64(data.count))
    }

    /// No raw caller path reaches Mail. Each call (including each retry) owns a
    /// different 0700 directory and leaf, so a stale success cannot reuse bytes.
    func saveUsingScript(_ run: (String) throws -> String, allowEmpty: Bool) throws -> String {
        let stage = try AttachmentStage()
        defer { stage.cleanUp() }
        let result = try run(stage.path)
        guard result.hasPrefix("Attachment saved") else { return result }
        let fd = openat(stage.directoryFd, AttachmentStage.leaf,
                        O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT {
                throw MailError.attachmentWriteUnverified(path: savePath, problem: .missing)
            }
            throw AttachmentDestinationError.io("cannot open staged attachment without following links")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw AttachmentDestinationError.io("cannot inspect staged attachment")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MailError.attachmentWriteUnverified(path: savePath, problem: .notRegular("staged non-regular file"))
        }
        guard info.st_size > 0 || allowEmpty else {
            throw MailError.attachmentWriteUnverified(path: savePath, problem: .empty)
        }
        do {
            try RaceFreeFileWriter.copyAttachment(dirFd: parentFd, name: filename,
                                                  sourceFd: fd, byteCount: info.st_size)
        } catch {
            throw AttachmentDestinationError.io("cannot publish staged attachment: \(error)")
        }
        return receipt(info.st_size)
    }

    private func receipt(_ size: Int64) -> String {
        "Attachment saved to \(savePath) " + (size == 0
            ? "(0 bytes — empty write accepted via allow_empty)" : "(\(size) bytes)")
    }
}

private final class AttachmentStage {
    static let leaf = "attachment"
    let directoryFd: Int32
    let directory: String
    var path: String { directory + "/" + Self.leaf }

    init() throws {
        var template = Array((FileManager.default.temporaryDirectory.path
                              + "/mail-attachment-" + UUID().uuidString + "-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else {
            throw AttachmentDestinationError.io("cannot create private attachment stage")
        }
        let directory = String(cString: template)
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(atPath: directory)
            throw AttachmentDestinationError.io("cannot open private attachment stage")
        }
        self.directory = directory
        self.directoryFd = fd
    }

    deinit { close(directoryFd) }

    func cleanUp() {
        do { try FileManager.default.removeItem(atPath: directory) }
        catch { Diagnostics.emit("save_attachment: private stage cleanup failed: \(error.localizedDescription)\n") }
    }
}
