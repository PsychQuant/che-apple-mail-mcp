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
    /// `--direct-transport-set-credential <address>` (#742): store the password
    /// read from standard input in the server's own keychain item.
    case setDirectTransportCredential(address: String)
    /// `--direct-transport-forget <message-id>` (#742): remove an unknown entry
    /// from the record of sent drafts.
    case forgetDirectTransportSend(messageID: String)
    /// A direct-transport flag without its value, or both at once.
    case usageError(String)

    /// Parse from raw `argv` (argv[0] is the binary path; flags follow). `--setup`
    /// wins over `--check-fda` if both are somehow present (GUI is the richer path).
    public static func parse(_ arguments: [String]) -> RunMode {
        let words = Array(arguments.dropFirst())
        let credential = words.firstIndex(of: "--direct-transport-set-credential")
        let forget = words.firstIndex(of: "--direct-transport-forget")
        if credential != nil && forget != nil {
            return .usageError("--direct-transport-set-credential and --direct-transport-forget cannot be combined")
        }
        // These change state, so they run only as the whole command line: a
        // `--version` or `--setup` that also carries one must not store or forget.
        if credential != nil {
            guard words.count == 2, credential == 0 else {
                return .usageError("--direct-transport-set-credential takes exactly one argument, the account's address, and nothing else")
            }
            return .setDirectTransportCredential(address: words[1])
        }
        if forget != nil {
            guard words.count == 2, forget == 0 else {
                return .usageError("--direct-transport-forget takes exactly one argument, the Message-ID the result named, and nothing else")
            }
            return .forgetDirectTransportSend(messageID: words[1])
        }
        let flags = Set(words)
        if flags.contains("--setup") { return .setup }
        if flags.contains("--check-fda") {
            return flags.contains("--quiet") ? .checkFDAQuiet : .checkFDA
        }
        if flags.contains("--version") { return .version }
        return .server
    }
}
