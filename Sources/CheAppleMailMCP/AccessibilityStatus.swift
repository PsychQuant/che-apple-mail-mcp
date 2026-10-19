import Foundation
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// Probe of whether this process is trusted for **Accessibility** (TCC) — the
/// permission that lets us drive System Events keystrokes (Cmd+S / Cmd+Shift+D),
/// the File ▸ Attach panel, and the sender popup during the #175 mailto-based
/// clean-body compose. This is a SEPARATE grant from Full Disk Access (see
/// `FDAStatus`): FDA covers reading `~/Library/Mail`; Accessibility covers GUI
/// scripting. macOS exposes a real query API here — `AXIsProcessTrusted()` — so,
/// unlike FDA, we can report the grant directly rather than probing a side effect.
///
/// Like FDA, the grant attaches to the process that LAUNCHED this server (the
/// terminal / Claude Desktop), not the binary itself — the guidance names
/// candidates, it never guesses.
enum AccessibilityStatus {

    enum Probe: Equatable {
        case granted       // AXIsProcessTrusted() == true — GUI scripting allowed
        case denied        // AXIsProcessTrusted() == false — keystrokes would silently fail
        case unsupported   // not macOS (defensive; this server is macOS-only)
    }

    /// Non-prompting check. We deliberately use `AXIsProcessTrusted()` rather
    /// than `AXIsProcessTrustedWithOptions(prompt: true)` so a probe never pops
    /// a system dialog as a side effect — the `--setup` window / `check_accessibility`
    /// tool drive the user to the settings pane explicitly instead.
    static func probe() -> Probe {
        #if canImport(ApplicationServices)
        return AXIsProcessTrusted() ? .granted : .denied
        #else
        return .unsupported
        #endif
    }

    /// Convenience: true iff GUI scripting is currently permitted.
    static var isTrusted: Bool { probe() == .granted }

    /// One-line human summary for CLI / `check_accessibility` tool output.
    static func summary(_ probe: Probe) -> String {
        switch probe {
        case .granted:
            return "Accessibility: GRANTED — GUI scripting (keystrokes, File ▸ Attach, sender popup) is allowed."
        case .denied:
            return "Accessibility: DENIED — this process can't send keystrokes, so the GUI compose paths are unavailable: compose_email / create_draft / reply_email / forward_email-with-a-body fail with a named reason; there is no fallback to the removed legacy path (#304). open_mailto needs no grant. With CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1, create_draft writes the draft directly, needing Full Disk Access and Automation rather than Accessibility, but only when the call meets the direct-write conditions; any other call takes the GUI path and fails."
        case .unsupported:
            return "Accessibility: UNSUPPORTED — not a macOS environment."
        }
    }

    /// Second line of `check_accessibility` output when the grant is present.
    static let grantedDetail = "compose_email / create_draft / reply_email / forward_email take their body from Mail's own"
        + " editor (#175/#304); a call that cannot run cleanly fails with a named reason; there is no fallback"
        + " to the removed legacy path. With CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1, create_draft writes the draft"
        + " directly (#472/#475) only when the call meets the direct-write conditions; any other call takes the GUI path. Note: System Events keystrokes also rely on Automation (Apple Events)"
        + " being allowed — this probe only checks Accessibility (AXIsProcessTrusted)."

    /// Caption under the Accessibility row of the setup window.
    static let setupNote = "Lets compose_email / create_draft send through Mail's native path so the body isn't shown as a quote on mobile (#175). Grant it to whatever LAUNCHED this server (terminal / Claude Desktop). Without it, the GUI compose paths fail with a named reason (no fallback to the removed legacy path, #304). The opt-in direct-write create_draft path does not need it, but it applies only when a call meets its conditions."

    /// Guidance text naming the candidates to grant (mirrors `FullDiskAccessHelp`).
    static func guidance() -> String {
        return """
        To enable the wrapper-free compose path (#175), grant Accessibility to the app that LAUNCHED this server:

          1. Open  System Settings ▸ Privacy & Security ▸ Accessibility
          2. Add (and enable) whichever launched this MCP server:
             • your terminal (Ghostty / Terminal / iTerm) — for Claude Code
             • Claude.app — for Claude Desktop
             (macOS can't tell us which one automatically — add whichever applies.)
          3. Re-run check_accessibility to confirm.

        Without it, the GUI compose paths fail with a named reason; there is no
        fallback to the removed legacy path (#304). open_mailto needs no grant (no
        attachments). With CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1, create_draft writes
        directly without Accessibility (it needs Full Disk Access and Automation),
        but only when the call meets the direct-write conditions.
        This is separate from Full Disk Access (see check_fda).
        """
    }
}
