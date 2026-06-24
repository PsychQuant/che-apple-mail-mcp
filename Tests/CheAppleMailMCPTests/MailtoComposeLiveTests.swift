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

    /// grep -rl for an .emlx under ~/Library/Mail containing `needle`; returns the
    /// first matching draft file path, polling up to ~15s for Mail to materialize
    /// the saved draft on disk.
    private func findDraftEmlx(containing needle: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for _ in 0..<15 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c",
                "grep -rl '\(needle)' \(home)/Library/Mail/V*/ 2>/dev/null | grep -i emlx | head -1"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty { return path }
            Thread.sleep(forTimeInterval: 1.0)
        }
        return nil
    }

    func testLive_createDraft_mailtoPath_producesWrapperFreeBody() async throws {
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

        // (a) The mailto branch returns a distinct success string; reaching it
        // proves the whole GUI chain ran without throwing (the window-identity /
        // sheet guards would have errored otherwise → legacy fallback string).
        XCTAssertTrue(result.contains("(mailto path)"),
                      "expected mailto path, got: \(result)")

        // (b) The ACTUAL regression assertion (#175 verify finding #4): read the
        // saved draft's .emlx off disk and confirm the body is wrapper-free —
        // this is the property the bug is about, which the return-string check
        // alone does NOT prove.
        guard let emlx = findDraftEmlx(containing: marker) else {
            XCTFail("saved draft .emlx not found on disk for marker \(marker)")
            return
        }
        let body = (try? String(contentsOfFile: emlx, encoding: .utf8)) ?? ""
        XCTAssertFalse(body.contains("blockquote type=\"cite\""),
                       "mailto draft body must NOT be wrapped in blockquote type=cite (#175): \(emlx)")
        XCTAssertFalse(body.contains("Apple-Mail-URLShareWrapperClass"),
                       "mailto draft body must NOT carry the Apple-Mail-URLShare wrapper (#175): \(emlx)")
    }
}
