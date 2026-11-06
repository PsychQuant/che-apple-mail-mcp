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

    /// How the probe reads the running-application list and the Apple Event
    /// permission. Injected so the #499 decision table is testable without
    /// Mail; `live` is the only production value.
    struct Environment {
        var isRunning: (String) -> Bool
        var determinePermission: (String) -> OSStatus
        var sleep: (TimeInterval) -> Void
        var log: (String) -> Void

        static let live = Environment(
            isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
            determinePermission: AutomationStatus.determinePermission,
            sleep: { Thread.sleep(forTimeInterval: $0) },
            log: { Diagnostics.emit($0) })
    }

    /// #499: re-checks of the running-application list, and the wait before each.
    static let runningListRechecks = 2
    static let runningListRecheckInterval: TimeInterval = 0.15

    /// Non-prompting probe of this process's permission to send Apple Events
    /// to `targetBundleId` (default: Mail).
    ///
    /// #499: `NSRunningApplication` can come back empty for a running Mail
    /// (seen under load in a test harness, 1–4 runs in 33), so an empty list is
    /// re-read up to `runningListRechecks` times, `runningListRecheckInterval`
    /// apart, before it counts. Only a list that stays empty yields
    /// `.targetNotRunning`. The Apple Event check still runs only for a target
    /// the list shows: it is not asked about a closed Mail, so the probe does
    /// exactly what it did before when Mail really is closed, 300 ms later.
    /// Each recovery is logged to stderr so the server's own rate is observable.
    static func probe(targetBundleId: String = "com.apple.mail",
                      environment: Environment = .live) -> State {
        if !environment.isRunning(targetBundleId) {
            guard let attempt = (1...runningListRechecks).first(where: { _ in
                environment.sleep(runningListRecheckInterval)
                return environment.isRunning(targetBundleId)
            }) else { return .targetNotRunning }
            environment.log("check_automation: running-application list was empty for "
                + "\(targetBundleId); re-check \(attempt) found it running (#499)\n")
        }
        return state(for: environment.determinePermission(targetBundleId))
    }

    /// The Apple Event permission status for `targetBundleId`, or the
    /// `AECreateDesc` error when the address cannot be built.
    static func determinePermission(_ targetBundleId: String) -> OSStatus {
        var addr = AEAddressDesc()
        let createErr = targetBundleId.withCString { cstr in
            AECreateDesc(typeApplicationBundleID, cstr, strlen(cstr), &addr)
        }
        guard createErr == noErr else { return OSStatus(createErr) }
        defer { AEDisposeDesc(&addr) }
        return AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, false)
    }

    /// Pure status → state mapping.
    static func state(for status: OSStatus) -> State {
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
                + "Run any AppleScript-backed Mail tool (e.g. get_mail_app_info — NOT "
                + "open_mailto, which uses LaunchServices and sends no Apple Events) and "
                + "macOS will show the "
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
