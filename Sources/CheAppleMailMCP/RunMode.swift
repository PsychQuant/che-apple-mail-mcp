import Foundation

/// How the binary was launched, parsed from `argv` **before** the stdio MCP
/// server starts. `--setup` / `--check-fda` divert to the onboarding paths
/// (#213); the default (no recognized flag) keeps the MCP stdio path
/// byte-for-byte untouched — that path must never link the GUI runloop.
public enum RunMode: Equatable {
    case server        // default — the stdio MCP server
    case setup         // --setup — the SwiftUI Full Disk Access setup window
    case checkFDA      // --check-fda — headless one-shot status print + open the pane
    /// `--check-fda --quiet` — exit status ONLY: no output, no settings pane
    /// (#355). A caller that wants to *detect* a missing grant (the plugin's
    /// session-start hook) must not, by asking, throw System Settings in the
    /// user's face on every session.
    case checkFDAQuiet
    case version       // --version — print AppVersion.current and exit (#303)

    /// Parse from raw `argv` (argv[0] is the binary path; flags follow). `--setup`
    /// wins over `--check-fda` if both are somehow present (GUI is the richer path).
    public static func parse(_ arguments: [String]) -> RunMode {
        let flags = Set(arguments.dropFirst())
        if flags.contains("--setup") { return .setup }
        if flags.contains("--check-fda") {
            return flags.contains("--quiet") ? .checkFDAQuiet : .checkFDA
        }
        if flags.contains("--version") { return .version }
        return .server
    }
}
