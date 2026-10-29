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
            return "Accessibility: DENIED — this process can't send keystrokes, so GUI-based composing calls (compose_email / create_draft / reply_email / forward_email-with-a-body) are refused before composition starts: they fail with a named reason; there is no fallback to the removed legacy path (#304). Grant Accessibility, or use open_mailto to open a clean compose window without TCC permission. With CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1, create_draft writes the draft directly, needing Full Disk Access and Automation rather than Accessibility, but only when the call meets the direct-write conditions; any other call takes the GUI path and is refused."
        case .unsupported:
            return "Accessibility: UNSUPPORTED — not a macOS environment."
        }
    }

    /// Caption under the Accessibility row of the setup window.
    static let setupNote = "Lets compose_email / create_draft send through Mail's native path so the body isn't shown as a quote on mobile (#175). Grant it to whatever LAUNCHED this server (terminal / Claude Desktop). Without it, the GUI compose paths fail with a named reason (no fallback to the removed legacy path, #304). The opt-in direct-write create_draft path does not need it, but it applies only when a call meets its conditions."

    /// Pure formatter shared by the tool and its tests; the probe stays at the caller.
    static func report(for probe: Probe) -> String {
        switch probe {
        case .granted:
            return "✅ " + summary(probe)
                + "\nEligible compose_email / create_draft calls use the clean compose path."
                + " Eight named preflight refusal reasons cover: non-plain format, empty subject,"
                + " missing Accessibility, a non-simple from_address, a non-ASCII attachment path,"
                + " display-name recipients on a SEND (drafts support names in to/cc/bcc),"
                + " a named signature that is missing or ambiguous in Mail,"
                + " or a mailto URL over 8000 encoded characters (MAILTO_URL_TOO_LONG)."
                + " A preflight refusal returns a named reason before composition starts."
                + " Other input validation can also fail before GUI steps."
                + " A GUI-step failure returns an error without switching to another body path;"
                + " it may leave a compose window or draft. A send-stage failure or timeout can"
                + " leave the send state unknown: check Sent/Outbox before sending again."
                + " This probe checks Accessibility only; Automation (Apple Events) is separately"
                + " required for System Events. Alternative: open_mailto needs zero TCC permission,"
                + " has no attachments, and opens the default mail client; drag files in manually"
                + " and save or send yourself. With CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1, create_draft"
                + " writes the draft directly (#472/#475) only when the call meets the direct-write"
                + " conditions; any other call takes the GUI path."
        case .denied:
            return "⚠️ " + summary(probe) + "\n\n" + guidance()
        case .unsupported:
            return "ℹ️ " + summary(probe)
        }
    }

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

        Without Accessibility, GUI-based composing calls are refused before
        composition starts. Use open_mailto instead: zero TCC permission,
        no attachments; drag files in manually and save or send yourself.
        It opens the system default mail client, which may not be Mail.app.
        With CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1, create_draft writes directly
        without Accessibility (it needs Full Disk Access and Automation), but only
        when the call meets the direct-write conditions.
        Accessibility is separate from Full Disk Access (check_fda) and
        Automation (check_automation).
        """
    }
}
