import Foundation

/// How the binary was launched, parsed from `argv` **before** the stdio MCP
/// server starts. `--setup` / `--check-fda` divert to the onboarding paths
/// (#213); the default (no recognized flag) keeps the MCP stdio path
/// byte-for-byte untouched — that path must never link the GUI runloop.
public enum RunMode: Equatable {
    case server        // default — the stdio MCP server
    case setup         // --setup — the SwiftUI Full Disk Access setup window
    case checkFDA      // --check-fda — headless one-shot status print + open the pane

    /// Parse from raw `argv` (argv[0] is the binary path; flags follow). `--setup`
    /// wins over `--check-fda` if both are somehow present (GUI is the richer path).
    public static func parse(_ arguments: [String]) -> RunMode {
        let flags = Set(arguments.dropFirst())
        if flags.contains("--setup") { return .setup }
        if flags.contains("--check-fda") { return .checkFDA }
        return .server
    }
}
