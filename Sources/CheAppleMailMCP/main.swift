import Foundation
import MCP

// Entry point for che-apple-mail-mcp.
// Parse the launch mode BEFORE starting the stdio server so the onboarding
// flags (--setup / --check-fda, #213) divert cleanly and the default MCP stdio
// path stays byte-for-byte untouched.
switch RunMode.parse(CommandLine.arguments) {
case .server:
    let server = try await CheAppleMailMCPServer()
    try await server.run()
case .checkFDA:
    SetupCLI.runCheckFDA()
case .setup:
    await SetupWindow.run()
}
