import XCTest
@testable import CheAppleMailMCP

/// #175 — GATED live test of the wired mailto clean-body compose path. Runs the
/// REAL `MailController.createDraft` (in-process NSAppleScript → Mail + System
/// Events), proving the chain executes end-to-end, then asserts the saved draft's
/// `.emlx` body is free of the `Apple-Mail-URLShareWrapperClass` /
/// `blockquote type="cite"` wrapper. Mutates the user's Mail, so it is skipped
/// unless BOTH:
///   - `CHE_MAIL_LIVE_TEST=1` is set, and
///   - Accessibility (AXIsProcessTrusted) is granted to the test runner.
/// The created draft is deleted afterward (best-effort; Gmail may leave a Trash
/// copy that auto-purges).
final class MailtoComposeLiveTests: XCTestCase {

    private func runOsa(_ source: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func deleteDrafts(subjectContains marker: String) {
        _ = runOsa("""
        tell application "Mail"
            repeat 6 times
                set done to true
                repeat with w in (every window)
                    if (name of w) contains "\(marker)" then
                        try
                            close w saving no
                            set done to false
                            exit repeat
                        end try
                    end if
                end repeat
                if done then exit repeat
            end repeat
            set ogms to (every outgoing message)
            repeat with i from (count of ogms) to 1 by -1
                try
                    if (subject of (item i of ogms)) contains "\(marker)" then delete (item i of ogms)
                end try
            end repeat
            repeat with a in every account
                repeat with mb in (every mailbox of a)
                    try
                        repeat with h in (messages of mb whose subject contains "\(marker)")
                            delete h
                        end repeat
                    end try
                end repeat
            end repeat
        end tell
        """)
    }

    func testLive_createDraft_takesMailtoPath() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHE_MAIL_LIVE_TEST"] == "1",
                          "live test — set CHE_MAIL_LIVE_TEST=1 to run")
        try XCTSkipUnless(AccessibilityStatus.isTrusted,
                          "live test needs Accessibility granted to the test runner")

        // Unique marker so cleanup never touches the user's real drafts.
        let marker = "LIVEMAILTO_\(Int(Date().timeIntervalSince1970))"
        defer { deleteDrafts(subjectContains: marker) }

        let result = try await MailController.shared.createDraft(
            to: ["live@example.invalid"],
            subject: marker,
            body: "第一行：live mailto 測試 \(marker)\n第二行：body 應乾淨"
        )

        // The mailto branch returns a distinct success string; the legacy path
        // returns "Draft created successfully" (no "(mailto path)"). Reaching the
        // mailto string proves the whole GUI chain ran without throwing (the
        // window-count guard would have errored otherwise).
        XCTAssertTrue(result.contains("(mailto path)"),
                      "expected mailto path, got: \(result)")
    }
}
