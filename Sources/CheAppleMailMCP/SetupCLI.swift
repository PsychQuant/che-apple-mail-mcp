import Foundation
import MailSQLite

/// Headless `--check-fda` flow: print the Full Disk Access status + the right
/// next step per state. It opens the settings pane **only** for `.denied` — the
/// one state where granting FDA is unambiguously the fix. No window — for
/// terminals, scripts, or a quick check. (#213)
enum SetupCLI {
    static func runCheckFDA() {
        let probe = FDAStatus.probe()
        print(FDAStatus.summary(probe))
        switch probe {
        case .granted:
            return
        case .noMailData:
            // ENOENT is ambiguous (no Mail vs FDA-denied hiding ~/Library/Mail) —
            // present both, and offer the grant steps for the FDA-denied case.
            print("")
            print("If Apple Mail IS configured, this most likely means Full Disk Access is denied "
                + "(a denial can hide ~/Library/Mail). Grant it:")
            print(FullDiskAccessHelp.guidance(reason: "If Full Disk Access is the cause:"))
            print("")
            print("If Mail genuinely isn't set up, add an account first, then re-run.")
        case .denied:
            print("")
            print(FullDiskAccessHelp.guidance(reason: "Full Disk Access is required for the SQLite fast path."))
            print("")
            print("Opening the Full Disk Access settings pane…")
            openSettingsPane()
        case .undetermined:
            // Not a clear permission denial — print steps but DON'T auto-open the
            // pane (it would imply this is an FDA problem when it may not be).
            print("")
            print("The Envelope Index couldn't be read due to an unexpected error (not a clear "
                + "permission denial). Retry first. If it persists and Full Disk Access might be the cause:")
            print(FullDiskAccessHelp.guidance(reason: "If Full Disk Access is the cause:"))
        }
    }

    /// Open the deep-link via `/usr/bin/open` so the CLI path needs no AppKit.
    private static func openSettingsPane() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [FullDiskAccessHelp.settingsDeepLink]
        try? proc.run()
        proc.waitUntilExit()
    }
}
