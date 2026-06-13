import Foundation

/// Errors thrown when a caller-provided `output_dir` fails the
/// `export_emails_markdown` write-safety check.
enum AllowedRootsError: Error, Equatable {
    /// The canonical (symlink-resolved) path is not the user's home nor
    /// within any configured allowed root.
    case escapesAllowedRoots(path: String)
    /// The canonical path resolves under a denied system directory
    /// (defence-in-depth, even if a misconfigured allowed root pointed there).
    case systemPath(path: String)
}

/// Validates a caller-supplied `output_dir` against an allowed-roots
/// whitelist before any file is written, preventing path traversal and
/// arbitrary file overwrite.
///
/// This is the security boundary for the MCP's first "write to an arbitrary
/// filesystem path" surface (issue #193, design decision D2). The validation
/// rule, in order:
///
/// 1. Canonicalize the path: expand `~`, collapse `.`/`..`, and resolve
///    symlinks on the deepest existing ancestor (a not-yet-created tail has
///    no symlinks of its own, so a symlinked ancestor cannot smuggle the real
///    path outside the roots).
/// 2. Reject if the canonical path is under a system directory denylist.
/// 3. Accept only if the canonical path equals or is nested under the user's
///    home directory or one of the configured allowed roots (each itself
///    canonicalized before comparison, so symlinked roots compare correctly).
struct AllowedRootsValidator {

    /// System directory prefixes that are never writable, regardless of the
    /// configured allowed roots. `/Library` here is the system-level Library;
    /// the user's `~/Library` resolves under home (`/Users/<u>/Library`) and
    /// does not match the `/Library/` prefix, so it is unaffected.
    static let systemDenylist: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/Library",
    ]

    init() {}

    /// Validate `outputDir` against the user's home plus `allowedRoots`.
    ///
    /// - Returns: the canonical (symlink-resolved, `..`-collapsed) URL that
    ///   the caller should create and write under. The directory need not
    ///   exist yet.
    /// - Throws: `AllowedRootsError.systemPath` if under a denied system dir;
    ///   `AllowedRootsError.escapesAllowedRoots` if outside all roots.
    func validate(_ outputDir: String, allowedRoots: [String]) throws -> URL {
        let canonical = Self.canonicalize(outputDir)
        let canonicalPath = canonical.path

        for deny in Self.systemDenylist {
            if canonicalPath == deny || canonicalPath.hasPrefix(deny + "/") {
                throw AllowedRootsError.systemPath(path: canonicalPath)
            }
        }

        var roots = [Self.canonicalize(NSHomeDirectory())]
        for root in allowedRoots where !root.isEmpty {
            roots.append(Self.canonicalize(root))
        }

        for root in roots {
            let rootPath = root.path
            if canonicalPath == rootPath || canonicalPath.hasPrefix(rootPath + "/") {
                return canonical
            }
        }
        throw AllowedRootsError.escapesAllowedRoots(path: canonicalPath)
    }

    /// Resolve a (possibly not-yet-existing) path to its canonical real path.
    ///
    /// Expands `~`, collapses `.`/`..` lexically, then walks up to the deepest
    /// existing ancestor and resolves its symlinks, re-appending the
    /// non-existent tail. The tail cannot contain symlinks (it doesn't exist),
    /// so the result reflects the true on-disk location a write would target.
    static func canonicalize(_ path: String) -> URL {
        let fm = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL

        var existing = standardized
        var tail: [String] = []
        while !fm.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }  // reached filesystem root
            tail.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }

        var result = existing.resolvingSymlinksInPath()
        for component in tail {
            result.appendPathComponent(component)
        }
        return result.standardizedFileURL
    }
}
