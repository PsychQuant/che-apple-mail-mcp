import Foundation
import MailSQLite

/// Headless `--check-fda` flow: print the Full Disk Access status + the right
/// next step per state, opening the settings pane only when granting FDA would
/// actually help. No window — for terminals, scripts, or a quick check. (#213)
enum SetupCLI {
    static func runCheckFDA() {
        let probe = FDAStatus.probe()
        print(FDAStatus.summary(probe))
        switch probe {
        case .granted:
            return
        case .noMailData:
            // Mail isn't set up — do NOT tell the user to grant FDA (it won't help).
            print("")
            print("Set up at least one account in Apple Mail, then re-run — Full Disk Access "
                + "status can't be determined until there is mail data to read.")
        case .denied:
            print("")
            print(FullDiskAccessHelp.guidance(reason: "Full Disk Access is required for the SQLite fast path."))
            print("")
            print("Opening the Full Disk Access settings pane…")
            openSettingsPane()
        case .undetermined:
            print("")
            print("The Envelope Index couldn't be read due to an unexpected error (not a clear "
                + "permission denial). Retry first. If it persists and Full Disk Access might be the cause:")
            print(FullDiskAccessHelp.guidance(reason: "If Full Disk Access is the cause:"))
            print("")
            print("Opening the Full Disk Access settings pane…")
            openSettingsPane()
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
