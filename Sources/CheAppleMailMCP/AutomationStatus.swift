import Foundation
import AppKit
import CoreServices

/// #293 — Automation-TCC probe, the third axis of the check_* family
/// (`check_fda` → Full Disk Access, `check_accessibility` → GUI scripting,
/// THIS → Apple Events to Mail). Modeled on che-ical-mcp's EventKit
/// `authorizationStatus` probe/setup pattern; the Apple-Events equivalent is
/// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false` —
/// a NON-PROMPTING status read (same discipline as `AccessibilityStatus`
/// deliberately avoiding the prompting variant).
///
/// Attribution model (#288, empirically verified): the signed binary holds
/// its OWN Automation grant — this probe only tells the truth because it is
/// issued BY the binary itself; a shell `osascript` probe would report the
/// terminal's grant, not ours.
enum AutomationStatus {

    enum State: Equatable {
        /// Apple Events to the target are permitted — AppleScript tools work.
        case granted
        /// -1743 recorded denial. macOS never re-prompts a remembered Deny.
        case denied
        /// -1744 — no decision recorded yet; the FIRST real Apple Event (any
        /// Mail tool call) will trigger the authorization prompt.
        case notDetermined
        /// The target app is not running — the AE permission check needs a
        /// live process to address. Deliberately NOT auto-launching Mail here:
        /// a probe must not have side effects.
        case targetNotRunning
        /// An OSStatus outside the documented set — surfaced verbatim, judged
        /// conservatively (treat like denied for remediation purposes).
        case unknown(OSStatus)
    }

    /// Non-prompting probe of this process's permission to send Apple Events
    /// to `targetBundleId` (default: Mail).
    static func probe(targetBundleId: String = "com.apple.mail") -> State {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: targetBundleId).isEmpty else {
            return .targetNotRunning
        }
        var addr = AEAddressDesc()
        let createErr = targetBundleId.withCString { cstr in
            AECreateDesc(typeApplicationBundleID, cstr, strlen(cstr), &addr)
        }
        guard createErr == noErr else { return .unknown(OSStatus(createErr)) }
        defer { AEDisposeDesc(&addr) }
        let status = AEDeterminePermissionToAutomateTarget(
            &addr, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):        // -1743
            return .denied
        case -1744:                                    // errAEEventWouldRequireUserConsent
            return .notDetermined
        case OSStatus(procNotFound):                   // -600 (race: quit mid-probe)
            return .targetNotRunning
        default:
            return .unknown(status)
        }
    }

    /// Pure state → report mapping (unit-tested; the probe itself is the thin
    /// live layer). Denied reuses `AutomationHelp.guidance` — single source of
    /// the remediation text (#288), never duplicated.
    static func report(for state: State) -> String {
        switch state {
        case .granted:
            return "✅ Automation permission GRANTED — this binary may send Apple Events "
                + "to Mail; all AppleScript-backed tools should work."
        case .denied:
            return "❌ Automation permission DENIED (recorded -1743 for this binary). "
                + AutomationHelp.guidance
        case .notDetermined:
            return "❓ Automation permission NOT DETERMINED — no decision recorded yet. "
                + "Run any Mail tool (e.g. get_mail_app_info) and macOS will show the "
                + "authorization prompt; click OK there. Note: the prompt names THIS "
                + "binary / its host, not your terminal (#288 — the binary holds its "
                + "own grant)."
        case .targetNotRunning:
            return "⚠️ Mail.app is not running — the Automation permission check needs "
                + "a live target process. Open Mail.app, then run check_automation again. "
                + "(The probe deliberately does not launch Mail itself: a status check "
                + "must not have side effects.)"
        case .unknown(let code):
            return "⚠️ Unexpected Apple Events status \(code) from the permission probe. "
                + "Treating conservatively as not-granted. "
                + AutomationHelp.guidance
        }
    }
}
