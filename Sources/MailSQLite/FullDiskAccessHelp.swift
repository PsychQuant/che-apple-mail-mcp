import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared, actionable guidance for the case where Apple Mail's Envelope Index
/// (the SQLite fast path) can't be read because **Full Disk Access (FDA)** is
/// not granted to the process responsible for this server.
///
/// Why this exists (#211 → corrected in #214): the read path used to fail with
/// a silent stderr line + AppleScript fallback, or a terse "...is unavailable"
/// throw. #211 made it loud but pinned the wrong target — it told users to grant
/// FDA to the MCP *binary*. macOS TCC actually checks the **responsible process**:
/// for an MCP server launched by Claude Code inside a terminal, that is the
/// *terminal app* (e.g. Ghostty / Terminal / iTerm), not the binary. Granting the
/// binary does nothing; granting the terminal once covers every MCP it launches.
/// This type resolves the responsible process at runtime and names it first, with
/// the binary kept as the direct-launch / Claude Desktop fallback.
///
/// Note on the deeper fix: FDA (`kTCCServiceSystemPolicyAllFiles`) has no
/// programmatic request API — an app can only deep-link to the settings pane.
/// A Developer ID-signed + notarized build makes the grant survive version bumps
/// (TCC binds it to the signing identity, not the binary's cdhash) — that matters
/// for the direct-launch path where the binary itself is the responsible process.
public enum FullDiskAccessHelp {

    /// Deep-link that opens System Settings → Privacy & Security → Full Disk Access.
    public static let settingsDeepLink =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// Absolute path of the currently-running binary. This is the FDA target only
    /// for the *direct-launch* case (the binary is its own responsible process) —
    /// for the common Claude-Code-in-a-terminal launch, the responsible process is
    /// the terminal, resolved by `responsibleProcessPath()`.
    ///
    /// Uses `_NSGetExecutablePath` (the real executable path) rather than
    /// `argv[0]`, which is not guaranteed to be the executable: a PATH launch
    /// gives a bare name, a symlink launch gives the link, and a launcher can
    /// rewrite it (#211 CODEX-4). Falls back to argv[0] only if that API fails.
    public static func binaryPath() -> String {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)   // first call: learn required size
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer)
                if !path.isEmpty {
                    // resolvingSymlinksInPath gives the canonical real path —
                    // the exact entry TCC matches against.
                    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                }
            }
        }
        #endif
        // Fallback: argv[0], best-effort.
        let argv0 = CommandLine.arguments.first ?? ""
        guard !argv0.isEmpty else { return "the CheAppleMailMCP binary" }
        if argv0.hasPrefix("/") { return argv0 }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: cwd))
            .standardizedFileURL.path
    }

    /// Absolute path of the **TCC responsible process** — the app macOS attributes
    /// this server's file access to (typically the terminal Claude Code runs in,
    /// e.g. Ghostty). Returns `nil` when there is no distinct responsible process
    /// (direct launch / Claude Desktop bundle — the binary is its own responsible
    /// process) or when the resolver is unavailable.
    ///
    /// Uses `responsibility_get_pid_responsible_for_pid`, the private libquarantine
    /// SPI that `launchctl procinfo` itself uses. We `dlsym` it from the global
    /// symbol table rather than linking it, so there is no hard dependency and we
    /// degrade cleanly to `nil` if a future macOS drops or renames the symbol.
    public static func responsibleProcessPath() -> String? {
        #if canImport(Darwin)
        typealias ResponsibleForPidFn = @convention(c) (pid_t) -> pid_t
        // RTLD_DEFAULT == (void *)-2: search every loaded image for the symbol.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let responsibleForPid = unsafeBitCast(sym, to: ResponsibleForPidFn.self)
        let myPid = getpid()
        let responsiblePid = responsibleForPid(myPid)
        // Same pid → we ARE the responsible process (direct launch / Claude
        // Desktop). Nothing distinct to point the user at; let the caller fall
        // back to the binary path.
        guard responsiblePid > 0, responsiblePid != myPid else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) — large enough for any path.
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(responsiblePid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
        #else
        return nil
        #endif
    }

    /// A full, multi-line actionable block. `reason` is a short lead-in
    /// describing what concretely failed (e.g. the SQLite open error).
    public static func guidance(reason: String) -> String {
        let binary = binaryPath()
        if let responsible = responsibleProcessPath() {
            return """
            \(reason)
            Apple Mail's Envelope Index (the SQLite fast path) requires Full Disk \
            Access. macOS grants it to the *responsible process* — the app that \
            launched this server — not to the binary itself.

            Grant it once:
              1. Open Full Disk Access settings: \(settingsDeepLink)
              2. Add / enable the app that launched this server: \(responsible)
                 This is your terminal (e.g. Ghostty / Terminal / iTerm) or Claude \
            Desktop, NOT the MCP binary. One grant there covers every MCP server it launches.
              3. Fully quit and reopen that app (Cmd+Q), then retry.

            If you instead launch this binary directly, grant Full Disk Access to \
            it: \(binary). A Developer ID-signed build makes that grant survive \
            version bumps.
            """
        }
        // No distinct responsible process resolved (direct launch / Claude Desktop,
        // or the SPI is unavailable) — name both targets so the user can't be misdirected.
        return """
        \(reason)
        Apple Mail's Envelope Index (the SQLite fast path) requires Full Disk \
        Access. macOS grants it to the *responsible process* — usually the app \
        that launched this server, not the binary itself.

        Grant it once:
          1. Open Full Disk Access settings: \(settingsDeepLink)
          2. Add / enable the app that launched this server: your terminal \
        (Ghostty / Terminal / iTerm) or Claude Desktop. One grant there covers \
        every MCP server it launches. If you launched this binary directly, add it instead: \(binary)
          3. Fully quit and reopen that app (Cmd+Q), then retry.

        With a Developer ID-signed build, the grant survives version bumps (it \
        binds to the signing identity, not the binary hash).
        """
    }

    /// Compact one-line suffix for short tool-call error strings.
    public static func unavailableSuffix() -> String {
        if let responsible = responsibleProcessPath() {
            return "Grant Full Disk Access to the app running this server — "
                + "\(responsible) (your terminal or Claude Desktop, not the MCP "
                + "binary) — via \(settingsDeepLink), then fully quit and reopen it."
        }
        return "Grant Full Disk Access to the app running this server (your "
            + "terminal — Ghostty / Terminal / iTerm — or Claude Desktop, not "
            + "necessarily this binary at \(binaryPath())) via \(settingsDeepLink), "
            + "then fully quit and reopen it."
    }
}
