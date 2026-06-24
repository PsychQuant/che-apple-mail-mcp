import Foundation
import MailSQLite
#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
#endif

/// The `--setup` GUI: a launch-on-demand window that shows live Full Disk Access
/// + Automation status, opens the right settings pane, and re-checks on a timer
/// so it flips to "Ready ✅" the instant the user grants. Gated behind --setup
/// (see `RunMode`): AppKit/SwiftUI are linked into the binary (load-time deps),
/// but this runloop only *starts* under --setup — the stdio MCP path never enters
/// it. (#213)
///
/// The window names *candidates* (terminal / Claude Desktop / binary), it does
/// NOT claim to auto-name the exact responsible app — there is no reliable
/// in-process API for that (#214). The functional probe is the source of truth.
enum SetupWindow {
    @MainActor
    static func run() {
        #if canImport(AppKit) && canImport(SwiftUI)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = SetupAppDelegate()
        app.delegate = delegate
        app.run()
        #else
        // Non-GUI platform — degrade to the headless flow rather than nothing.
        SetupCLI.runCheckFDA()
        #endif
    }
}

#if canImport(AppKit) && canImport(SwiftUI)
@MainActor
final class SetupAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: SetupView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "CheAppleMailMCP — Full Disk Access Setup"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 480, height: 560))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var fda: FDAStatus.Probe = FDAStatus.probe()
    @Published var automation: Bool?
    /// #175: Accessibility drives the wrapper-free mailto compose path.
    @Published var accessibility: AccessibilityStatus.Probe = AccessibilityStatus.probe()
    private var timer: Timer?

    func start() {
        // Idempotent: a view re-appear (miniaturize/deminiaturize re-runs onAppear
        // while the @StateObject persists) must not leak a second repeating timer.
        stop()
        refresh()
        // Live re-check so the window flips to Ready the moment the user grants.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        fda = FDAStatus.probe()
        accessibility = AccessibilityStatus.probe()
    }

    var binaryPath: String { FullDiskAccessHelp.binaryPath() }

    func openFDASettings() {
        if let url = URL(string: FullDiskAccessHelp.settingsDeepLink) {
            NSWorkspace.shared.open(url)
        }
    }

    /// #175: deep-link to System Settings ▸ Privacy & Security ▸ Accessibility.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyBinaryPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(binaryPath, forType: .string)
    }

    /// Sending a benign Apple Event to Mail triggers the Automation prompt (the
    /// one TCC surface that DOES auto-prompt, unlike FDA).
    func checkAutomation() {
        let source = "tell application \"Mail\" to get the name of every account"
        var err: NSDictionary?
        if let apple = NSAppleScript(source: source) {
            _ = apple.executeAndReturnError(&err)
            automation = (err == nil)
        } else {
            automation = false
        }
    }
}

struct SetupView: View {
    @StateObject private var model = SetupModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apple Mail access setup").font(.title2).bold()

            // Full Disk Access
            HStack(alignment: .top, spacing: 10) {
                dot(model.fda == .granted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access").bold()
                    Text(FDAStatus.summary(model.fda))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Text("macOS grants Full Disk Access to the app that LAUNCHED this server — your terminal (Ghostty / Terminal / iTerm) for Claude Code, or Claude Desktop. If you run the binary directly, grant the binary below. macOS can't tell us which one automatically, so add whichever launched this server.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Full Disk Access settings") { model.openFDASettings() }
                Button("Copy binary path") { model.copyBinaryPath() }
            }
            Text(model.binaryPath)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(.secondary)

            Divider()

            // Automation
            HStack(alignment: .top, spacing: 10) {
                automationDot(model.automation)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automation (control Mail.app)").bold()
                    Text(automationLabel).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Check") { model.checkAutomation() }
            }

            Divider()

            // Accessibility (#175 — wrapper-free compose path)
            HStack(alignment: .top, spacing: 10) {
                dot(model.accessibility == .granted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility (clean compose)").bold()
                    Text(AccessibilityStatus.summary(model.accessibility))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open settings") { model.openAccessibilitySettings() }
            }
            Text("Lets compose_email / create_draft send through Mail's native path so the body isn't shown as a quote on mobile (#175). Grant it to whatever LAUNCHED this server (terminal / Claude Desktop). Without it, compose still works but the body is wrapped.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if model.fda == .granted {
                Text("Full Disk Access ✅ granted — the read / SQLite path is ready. (Automation, above, is a separate grant; check it if you use Mail-control features.)")
                    .foregroundColor(.green).bold()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 530, alignment: .topLeading)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var automationLabel: String {
        switch model.automation {
        case .none: return "Not checked yet (click Check — it triggers the macOS prompt)"
        case .some(true): return "Allowed"
        case .some(false): return "Denied"
        }
    }

    @ViewBuilder private func dot(_ ok: Bool) -> some View {
        Circle()
            .fill(ok ? Color.green : Color.red)
            .frame(width: 12, height: 12)
            .padding(.top, 3)
    }

    /// Three-state dot for Automation: gray for "not checked yet" so it doesn't
    /// read as a red "denied" before the user has clicked Check.
    @ViewBuilder private func automationDot(_ state: Bool?) -> some View {
        let color: Color = state == nil ? .gray : (state! ? .green : .red)
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .padding(.top, 3)
    }
}
#endif
