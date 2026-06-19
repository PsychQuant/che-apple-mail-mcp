import Foundation
import MailSQLite

/// Headless `--check-fda` flow: print the Full Disk Access status + the exact
/// grant steps, and open the settings pane. No window — for terminals, scripts,
/// or a quick "am I set up?" check. (#213)
enum SetupCLI {
    static func runCheckFDA() {
        let probe = FDAStatus.probe()
        print(FDAStatus.summary(probe))
        guard probe != .granted else { return }
        print("")
        print(FullDiskAccessHelp.guidance(reason: "Full Disk Access is required for the SQLite fast path."))
        print("")
        print("Opening the Full Disk Access settings pane…")
        openSettingsPane()
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
