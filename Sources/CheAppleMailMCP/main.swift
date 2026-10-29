import Foundation
import MCP

// #320 — ignore SIGPIPE process-wide, before any transport starts.
//
// The kernel's default disposition kills the process on a write to a broken
// pipe BEFORE write() returns to Swift, so no try?/do-catch can intercept it.
// This server has ~26 FileHandle.standardError.write sites and a stdout-based
// stdio transport; a host that closes its read end while the server lives
// turned any of them into a silent SIGKILL-style death (verified on the real
// binary: broken-pipe stderr + a startup diagnostic → killed by signal 13).
//
// With SIG_IGN the write returns EPIPE as an errno instead: the throwing
// stderr writes swallow it (advisory diagnostics must not kill the server),
// and stdin EOF still ends the stdio receive loop. StdioShutdownTests (#329)
// separately pin progress during blocked Mail work; SIG_IGN does not provide
// that scheduling guarantee.
signal(SIGPIPE, SIG_IGN)

// Entry point for che-apple-mail-mcp.
// Parse the launch mode BEFORE starting the stdio server so the onboarding
// flags (--setup / --check-fda, #213) divert cleanly and the default MCP stdio
// path stays byte-for-byte untouched.
switch RunMode.parse(CommandLine.arguments) {
case .server:
    do {
        try publishWrapperRuntimeState(version: AppVersion.current)
    } catch {
        MailController.emitDiagnostic("wrapper runtime state update failed: \(error.localizedDescription)")
    }
    let server = try await CheAppleMailMCPServer()
    try await server.run()
case .checkFDA:
    exit(SetupCLI.runCheckFDA())
case .checkFDAQuiet:
    exit(SetupCLI.runCheckFDAQuiet())
case .setup:
    await SetupWindow.run()
case .version:
    // #303: lets `scripts/release.sh` interrogate the ACTUAL shipped artifact
    // (each slice of the universal binary) instead of separately compiling a
    // host-only probe — which a legal `#if arch(...)` or `#if compiler(...)`
    // in Version.swift could make disagree with what ships.
    print(AppVersion.current)
}
