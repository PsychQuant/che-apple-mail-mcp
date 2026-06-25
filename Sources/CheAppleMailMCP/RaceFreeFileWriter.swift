import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors from the race-free, `openat`-relative write path (#200).
enum RaceFreeWriteError: Error, Equatable {
    case openRootFailed(path: String, errno: Int32)
    case emptyComponents
    case mkdirFailed(component: String, errno: Int32)
    /// A path component was a symlink (`O_NOFOLLOW` → `ELOOP`) — the TOCTOU swap.
    case symlinkComponent(component: String)
    case openDirFailed(component: String, errno: Int32)
    /// The leaf file couldn't be exclusively created (`O_EXCL` collision / a
    /// symlinked target via `O_NOFOLLOW` / other).
    case createFailed(name: String, errno: Int32)
    case writeFailed(name: String, errno: Int32)
}

/// Race-free file writing for `export_emails_markdown` (#200).
///
/// The `export_emails_markdown` write previously validated `output_dir` for
/// symlink escape, then `createDirectory`'d + wrote **later** — a concurrent
/// local actor planting a symlink in that window could redirect the write
/// outside the validated tree (validate→write TOCTOU). This descends from a
/// validated directory **file descriptor** using `openat` / `mkdirat` with
/// `O_NOFOLLOW`, and creates files with `O_CREAT | O_EXCL | O_NOFOLLOW`, so no
/// path component is ever re-resolved through a (possibly newly-planted) symlink.
enum RaceFreeFileWriter {

    /// High-level convenience: race-free-write `data` to
    /// `<rootDir>/<relativeDirComponents…>/<filename>`. Opens the validated
    /// `rootDir` (no-follow), descends `relativeDirComponents` creating each dir
    /// no-follow, then atomically writes `filename`. All fds are opened + closed
    /// internally — callers never touch raw descriptors. `relativeDirComponents`
    /// empty → write directly in `rootDir`.
    static func writeFile(rootDir: String, relativeDirComponents: [String], filename: String, data: Data) throws {
        let rootFd = try openValidatedRootDir(rootDir)
        defer { close(rootFd) }
        if relativeDirComponents.isEmpty {
            try writeFileAtomicNoFollow(dirFd: rootFd, name: filename, data: data)
        } else {
            let leafFd = try descendCreatingDirs(rootFd: rootFd, components: relativeDirComponents)
            defer { close(leafFd) }
            try writeFileAtomicNoFollow(dirFd: leafFd, name: filename, data: data)
        }
    }

    /// Open an already-validated canonical directory as a fd. The directory is
    /// the `AllowedRootsValidator`-checked, symlink-resolved root, so `O_NOFOLLOW`
    /// on the final component only adds protection (it must be a real dir).
    /// Caller owns the returned fd and must `close` it.
    static func openValidatedRootDir(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 {
            throw RaceFreeWriteError.openRootFailed(path: path, errno: errno)
        }
        return fd
    }

    /// Descend `components` below `rootFd`, creating each directory (`mkdirat`,
    /// tolerating `EEXIST`) and re-opening it `O_DIRECTORY | O_NOFOLLOW`. A
    /// symlinked component fails `openat` with `ELOOP` → `symlinkComponent`.
    ///
    /// Returns the **leaf** directory fd (caller owns + closes it); all
    /// intermediate fds are closed before returning. `rootFd` is never closed.
    static func descendCreatingDirs(rootFd: Int32, components: [String]) throws -> Int32 {
        guard !components.isEmpty else { throw RaceFreeWriteError.emptyComponents }

        var parentFd = rootFd
        var openedNonRoot: [Int32] = []
        do {
            for component in components {
                if mkdirat(parentFd, component, 0o755) != 0 {
                    let e = errno
                    if e != EEXIST {
                        throw RaceFreeWriteError.mkdirFailed(component: component, errno: e)
                    }
                }
                // Explicitly detect a symlink at this component (the TOCTOU swap)
                // for a precise error — `O_DIRECTORY | O_NOFOLLOW` on a
                // symlink-to-dir fails ENOTDIR, not ELOOP, on Darwin.
                var st = stat()
                if fstatat(parentFd, component, &st, AT_SYMLINK_NOFOLLOW) == 0,
                   (st.st_mode & S_IFMT) == S_IFLNK {
                    throw RaceFreeWriteError.symlinkComponent(component: component)
                }
                // Open without following symlinks (still guards a swap after the
                // stat above — O_NOFOLLOW makes that open fail too).
                let fd = openat(parentFd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if fd < 0 {
                    let e = errno
                    throw e == ELOOP
                        ? RaceFreeWriteError.symlinkComponent(component: component)
                        : RaceFreeWriteError.openDirFailed(component: component, errno: e)
                }
                openedNonRoot.append(fd)
                parentFd = fd
            }
        } catch {
            for fd in openedNonRoot { close(fd) }
            throw error
        }

        let leaf = openedNonRoot.removeLast()
        for fd in openedNonRoot { close(fd) }   // close intermediates, keep the leaf
        return leaf
    }

    /// Atomically create-or-replace `name` under `dirFd` **without following a
    /// symlink** at any point. Writes to a sibling temp via
    /// `O_CREAT | O_EXCL | O_NOFOLLOW`, then `renameat`s it over `name` — so a
    /// symlink planted at `name` is *replaced* (never followed, the write lands
    /// inside `dirFd`), a crash mid-write never leaves a partial file at `name`
    /// (matching the prior `.atomic` semantics), and idempotent **re-export**
    /// (overwriting an existing `.md`) still works. Filenames are uniquified
    /// per run, so the temp never collides within a run; a stale temp from a
    /// crashed prior run is cleared first.
    static func writeFileAtomicNoFollow(dirFd: Int32, name: String, data: Data) throws {
        let tempName = name + ".idd200.tmp"
        if unlinkat(dirFd, tempName, 0) != 0 && errno != ENOENT {
            throw RaceFreeWriteError.createFailed(name: tempName, errno: errno)
        }
        let fd = openat(dirFd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        if fd < 0 {
            throw RaceFreeWriteError.createFailed(name: tempName, errno: errno)
        }
        do {
            defer { close(fd) }
            try writeAll(fd: fd, name: name, data: data)
        } catch {
            _ = unlinkat(dirFd, tempName, 0)   // best-effort cleanup
            throw error
        }
        if renameat(dirFd, tempName, dirFd, name) != 0 {
            let e = errno
            _ = unlinkat(dirFd, tempName, 0)
            throw RaceFreeWriteError.writeFailed(name: name, errno: e)
        }
    }

    private static func writeAll(fd: Int32, name: String, data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }   // empty data → file already created
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw RaceFreeWriteError.writeFailed(name: name, errno: errno)
                }
                offset += written
            }
        }
    }
}
