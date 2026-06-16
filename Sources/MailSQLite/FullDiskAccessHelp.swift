import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared, actionable guidance for the case where Apple Mail's Envelope Index
/// (the SQLite fast path) can't be read because **Full Disk Access (FDA)** is
/// not granted to *this* binary.
///
/// Why this exists (#211): the read path used to fail with either a silent
/// stderr line + AppleScript fallback, or a terse "...is unavailable" throw,
/// and the only FDA hint said to grant access to "the terminal application" —
/// wrong for an MCP server launched by Claude Code. This type centralizes one
/// loud, actionable message (deep-link to the FDA settings pane + the exact
/// running-binary path) so every failure site is consistent and testable.
///
/// Note on the deeper fix: FDA (`kTCCServiceSystemPolicyAllFiles`) has no
/// programmatic request API — an app can only deep-link to the settings pane.
/// A Developer ID-signed + notarized build makes the grant survive version
/// bumps (TCC binds it to the signing identity, not the binary's cdhash).
public enum FullDiskAccessHelp {

    /// Deep-link that opens System Settings → Privacy & Security → Full Disk Access.
    public static let settingsDeepLink =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// Absolute path of the currently-running binary — the EXACT entry the user
    /// must add to the Full Disk Access list. Deliberately not "the terminal
    /// application": this MCP server is launched by Claude Code, not a terminal.
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
    public static func guidance(reason: String) -> String {
        """
        \(reason)
        Apple Mail's Envelope Index (the SQLite fast path) requires Full Disk \
        Access, which is not granted to this binary.

        Grant it once:
          1. Open Full Disk Access settings: \(settingsDeepLink)
          2. Add / enable this exact binary: \(binaryPath())
          3. Fully quit and reopen Claude (Cmd+Q), then retry.

        With a Developer ID-signed build, the grant survives version bumps (it \
        binds to the signing identity, not the binary hash).
        """
    }

    /// Compact one-line suffix for short tool-call error strings.
    public static func unavailableSuffix() -> String {
        "Grant Full Disk Access to \(binaryPath()) (\(settingsDeepLink)), "
            + "then fully quit and reopen Claude."
    }
}
