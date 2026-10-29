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
    /// The canonical path resolves under a denied **home-relative** directory
    /// (#197) — `~/Library`, `~/.ssh`, `~/.config`, dotfiles, `~/bin`, … — the
    /// real macOS persistence / code-exec targets. Applies even in the default
    /// "all of `$HOME`" mode, and even if such a path were a configured root.
    case deniedHomePath(path: String)
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

    /// First-component-under-home names that are never writable (#197), even in
    /// the default "all of `$HOME`" mode. These are the real macOS persistence /
    /// code-exec / credential targets. Deliberately an **explicit** set, not a
    /// blanket "any dotfile" rule, so a legitimate `~/.mailarchive` is not
    /// surprised — a deployment wanting a hidden export dir can configure it via
    /// `CHE_MAIL_EXPORT_ALLOWED_ROOTS`. The list is inherently incomplete (the
    /// documented residual); the strict-allowlist config is the escape hatch.
    ///
    /// **Entries are lowercase and matched case-INSENSITIVELY** (see `validate`):
    /// the default macOS volume is case-insensitive APFS, so `~/.KUBE` and
    /// `~/.kube` are the *same* directory. A case-sensitive match would let
    /// `~/.KUBE/config` (an absent dir whose case `canonicalize` can't normalize)
    /// slip past while still resolving to the real `~/.kube/config` inode — a
    /// credential-exfiltration bypass (6-AI verify, Security + Devil's-Advocate).
    static let homeRelativeDenylist: Set<String> = [
        "library", "bin", "applications",
        ".ssh", ".config", ".gnupg", ".aws", ".docker", ".kube", ".local",
        ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile",
        ".netrc", ".pgpass", ".git-credentials", ".gitconfig",
        // #402 verify: save_attachment publishes sender-chosen bytes, so the
        // remaining shell startup files and the agent configuration this
        // server runs under are denied too.
        ".zshenv", ".zlogin", ".zlogout", ".bash_login", ".bash_logout",
        ".claude", ".claude.json", ".mcp.json", ".codex", ".cursor",
    ]

    /// Cloud-sync storage that macOS keeps inside `~/Library` (#402 verify):
    /// an existing provider folder in `~/Library/CloudStorage` (Dropbox, Google
    /// Drive, OneDrive, Box; `~/Dropbox` is a link into it); iCloud Drive,
    /// `~/Library/Mobile Documents/com~apple~CloudDocs`; and the `Documents`
    /// folder of each app's iCloud container, which Finder shows inside iCloud
    /// Drive (an Obsidian vault, Pages documents). Their contents are the user's
    /// own documents, so paths inside them are not denied with the rest of
    /// `~/Library`. The rest of each app container (Mail keeps its synced
    /// signatures in `com~apple~mail/Data`) stays denied, and so does anything
    /// directly under `CloudStorage` that is not an existing provider folder.
    static func isCloudSyncPath(_ components: [Substring], homePath: String,
                                directoryExists: (String) -> Bool) -> Bool {
        guard components.count >= 3, fold(components[0]) == "library" else { return false }
        switch fold(components[1]) {
        case "mobile documents":
            if fold(components[2]) == "com~apple~clouddocs" { return true }
            // An app container's Documents folder must already exist, as a
            // CloudStorage provider folder must: a save cannot create one.
            return components.count >= 4 && fold(components[3]) == "documents"
                && directoryExists(homePath + "/" + components[0...3].joined(separator: "/"))
        case "cloudstorage":
            return directoryExists(homePath + "/" + components[0...2].joined(separator: "/"))
        default:
            return false
        }
    }

    static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Where the denied home names really are (#402 verify). A dotfile kept in a
    /// cloud-sync folder or a dotfiles repository (`~/.zshrc` →
    /// `~/Library/CloudStorage/Dropbox/dotfiles/.zshrc`, `~/.claude/hooks` →
    /// `~/Developer/<config repo>/hooks`, `~/Library/LaunchAgents` restored by
    /// Mackup) resolves outside the denied name, so checking names alone would
    /// let a write through the target replace it. Covered: a denied name that
    /// is a link, and a link directly inside a denied directory, including
    /// links whose target does not exist yet. Not covered: links deeper inside
    /// a denied directory; that is the limit of a denylist, and configured
    /// roots are the way to narrow writes further.
    static func resolvedDeniedTargets(homePath: String) -> [String] {
        // The names as they are on disk: on a case-sensitive volume `~/Library`
        // cannot be reached as `~/library` (#402 verify).
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: homePath)) ?? [])
            .filter { homeRelativeDenylist.contains(fold(Substring($0))) }
        var targets: [String] = []
        for name in names.sorted() {
            let path = homePath + "/" + name
            if let target = linkTarget(path) { targets.append(target) }
            // A denied folder that is itself a link (stow's tree folding) is
            // searched through the link.
            var info = stat()
            guard fstatat(AT_FDCWD, path, &info, 0) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for child in children {
                if let target = linkTarget(path + "/" + child) { targets.append(target) }
            }
        }
        return targets
    }

    /// Where a link points, resolved as far as the filesystem allows. A link to
    /// something that does not exist yet still names it.
    static func linkTarget(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return nil }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var budget = 8
        return resolvingLinks(path, budget: &budget)
    }

    /// Resolve `path` one component at a time, following every link met on the
    /// way (a dangling one partway along included) until a component does not
    /// exist; the rest is kept as written. At most `budget` links are followed.
    private static func resolvingLinks(_ path: String, budget: inout Int) -> String? {
        var pending = path.split(separator: "/").map(String.init)
        var resolved = ""   // "" stands for "/"
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                if resolved == "/" { resolved = "" }
                continue
            }
            let candidate = resolved + "/" + component
            var info = stat()
            guard lstat(candidate, &info) == 0 else {
                guard errno == ENOENT else { return nil }
                return ([candidate] + pending).joined(separator: "/")
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                guard budget > 0, let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
                    return nil
                }
                budget -= 1
                if raw.hasPrefix("/") { resolved = "" }
                pending = raw.split(separator: "/").map(String.init) + pending
                continue
            }
            resolved = candidate
        }
        return resolved.isEmpty ? "/" : resolved
    }

    /// The home-name rule alone, for a path in any representation: the caller's
    /// own spelling of the path is checked as well as its resolved form, so
    /// `~/.zshrc` is denied even when it is a link into a permitted folder.
    func checkHomeNames(_ path: String, homePath: String,
                        directoryExists: (String) -> Bool = AllowedRootsValidator.isExistingDirectory) throws {
        // The home prefix is compared folded too: `/users/<u>` names the same
        // directory as `/Users/<u>` on the default volume (#402 verify).
        let foldedPath = Self.fold(Substring(path)), foldedHome = Self.fold(Substring(homePath))
        guard foldedPath == foldedHome || foldedPath.hasPrefix(foldedHome + "/") else { return }
        let components = path.dropFirst(homePath.count).split(separator: "/")
        // Case-INSENSITIVE: the default macOS volume is case-insensitive APFS,
        // so `~/.KUBE` == `~/.kube` on disk; a case-sensitive match would let
        // an absent-dir case variant bypass the denylist (6-AI verify).
        if let first = components.first, Self.homeRelativeDenylist.contains(Self.fold(first)),
           !Self.isCloudSyncPath(components, homePath: homePath, directoryExists: directoryExists) {
            throw AllowedRootsError.deniedHomePath(path: path)
        }
    }

    /// The comparison the default case-insensitive APFS volume makes: full case
    /// folding plus canonical normalization. `lowercased()` is not enough —
    /// APFS folds `ſ` to `s`, so `~/.ſſh` opens `~/.ssh` (#402 verify).
    static func fold(_ component: Substring) -> String {
        String(component).decomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil)
    }

    init() {}

    /// Validate `outputDir` against the user's home plus `allowedRoots`.
    ///
    /// - Returns: the canonical (symlink-resolved, `..`-collapsed) URL that
    ///   the caller should create and write under. The directory need not
    ///   exist yet.
    /// - Throws: `AllowedRootsError.systemPath` if under a denied system dir;
    ///   `AllowedRootsError.escapesAllowedRoots` if outside all roots.
    func validate(_ outputDir: String, allowedRoots: [String]) throws -> URL {
        let lexical = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath).standardizedFileURL.path
        try checkHomeNames(lexical, homePath: URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
        let canonical = Self.canonicalize(outputDir)
        try validateCanonicalPath(canonical.path,
                                  homePath: Self.canonicalize(NSHomeDirectory()).path,
                                  allowedRoots: allowedRoots.filter { !$0.isEmpty }
                                    .map { Self.canonicalize($0).path })
        return canonical
    }

    /// Policy-only entry for callers that already resolved the path they will
    /// use. Never resolve this candidate again: a second symlink lookup can
    /// authorize a different file while the caller retains the first (#402).
    /// Home and roots must use the same canonical representation as candidate.
    func validateCanonicalPath(_ canonicalPath: String, homePath: String, allowedRoots: [String],
                               deniedTargets: [String]? = nil,
                               directoryExists: (String) -> Bool = AllowedRootsValidator.isExistingDirectory) throws {
        for deny in Self.systemDenylist {
            if canonicalPath == deny || canonicalPath.hasPrefix(deny + "/") {
                throw AllowedRootsError.systemPath(path: canonicalPath)
            }
        }

        // #197: home-relative denylist — refuse the sensitive home subdirs even
        // in the default all-of-home mode (and even if such a path were a
        // configured root). Runs on the canonical, `..`-collapsed path so
        // `~/Documents/../Library` is caught.
        try checkHomeNames(canonicalPath, homePath: homePath, directoryExists: directoryExists)
        let foldedPath = Self.fold(Substring(canonicalPath))
        for target in deniedTargets ?? Self.resolvedDeniedTargets(homePath: homePath) {
            let foldedTarget = Self.fold(Substring(target))
            if foldedPath == foldedTarget || foldedPath.hasPrefix(foldedTarget + "/") {
                throw AllowedRootsError.deniedHomePath(path: canonicalPath)
            }
        }

        // #197: roots policy. No configured roots → default to the user's home
        // (backward-compatible). One or more configured roots → those REPLACE
        // home (opt-in strict allowlist / deny-by-default).
        let roots = allowedRoots.isEmpty ? [homePath] : allowedRoots
        for rootPath in roots {
            // A root of "/" has no "//" prefix to match, so name it explicitly.
            if rootPath == "/" || canonicalPath == rootPath || canonicalPath.hasPrefix(rootPath + "/") {
                return
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
