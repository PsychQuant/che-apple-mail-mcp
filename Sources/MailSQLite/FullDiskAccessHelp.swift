import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared, actionable guidance for the case where Apple Mail's Envelope Index
/// (the SQLite fast path) can't be read because **Full Disk Access (FDA)** is
/// not granted to the process responsible for this server.
///
/// Why this exists (#211 → corrected in #214): the read path used to fail with a
/// silent stderr line + AppleScript fallback, or a terse "...is unavailable"
/// throw. #211 made it loud but pinned the wrong target — it told users to grant
/// FDA to the MCP *binary*. macOS TCC actually grants FDA to the **responsible
/// process**: for an MCP server launched by Claude Code inside a terminal, that
/// is the *terminal app* (e.g. Ghostty / Terminal / iTerm), not the binary.
/// Granting the binary does nothing; granting the terminal once covers every MCP
/// it launches. This message names the responsible process first (the launching
/// app), and keeps the binary as the direct-launch / Claude Desktop fallback.
///
/// Why we don't auto-resolve and print the exact responsible app: empirically
/// (#214) there is no reliable in-process API for it. `launchctl procinfo` shows
/// a "responsible path" but computes it as root via a different mechanism; the
/// libquarantine SPI `responsibility_get_pid_responsible_for_pid(getpid())`
/// returns *self* for terminal- and CLI-launched processes (verified from a
/// Ghostty-launched binary and from a Claude Code subagent), so it does not yield
/// the terminal. Rather than ship a resolver that silently never fires, the
/// message names the likely candidates and lets the user pick.
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
    /// for the *direct-launch* / Claude Desktop case (the binary is then its own
    /// responsible process) — for the common Claude-Code-in-a-terminal launch, the
    /// responsible process is the terminal, which the user must add instead.
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

    /// A full, multi-line actionable block. `reason` is a short lead-in
    /// describing what concretely failed (e.g. the SQLite open error).
    ///
    /// Pure: no syscalls, just string construction from `binaryPath()`.
    public static func guidance(reason: String) -> String {
        """
        \(reason)
        Apple Mail's Envelope Index (the SQLite fast path) requires Full Disk \
        Access. macOS grants it to the *responsible process* — the app that \
        launched this server — not to the binary itself.

        Grant it once:
          1. Open Full Disk Access settings: \(settingsDeepLink)
          2. Add / enable the app that launched this server:
             - Claude Code in a terminal -> your terminal app (Ghostty / Terminal \
        / iTerm). One grant there covers every MCP server it launches.
             - Claude Desktop, or running the binary directly -> \(binaryPath())
          3. Fully quit and reopen that app (Cmd+Q), then retry.

        With a Developer ID-signed build, the direct-launch grant survives version \
        bumps (it binds to the signing identity, not the binary hash).
        """
    }

    /// Compact one-line suffix for short tool-call error strings.
    ///
    /// Pure: no syscalls, just string construction from `binaryPath()`.
    public static func unavailableSuffix() -> String {
        "Grant Full Disk Access to the app running this server — your terminal "
            + "(Ghostty / Terminal / iTerm) for Claude Code, or \(binaryPath()) "
            + "for Claude Desktop / direct launch — via \(settingsDeepLink), then "
            + "fully quit and reopen it."
    }
}
