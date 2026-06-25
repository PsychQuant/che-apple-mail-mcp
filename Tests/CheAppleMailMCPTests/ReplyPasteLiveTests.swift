import XCTest
@testable import CheAppleMailMCP

/// #218 — GATED live test of the wired wrapper-free reply paste path. Runs the
/// REAL `MailController.replyEmail(saveAsDraft: true)` (in-process → Mail + System
/// Events), then asserts the saved reply draft's `.emlx`:
///   (a) the NEW body is free of the `Apple-Mail-URLShareWrapperClass` wrapper
///       (the #218/#175 signature the clean path never emits), AND
///   (b) Mail's NATIVE quoted original is still present (a `blockquote type=cite`),
///       with the new body sitting ABOVE the quote (not wrapped inside it).
///
/// Mutates the user's Mail, so it is skipped unless BOTH:
///   - `CHE_MAIL_LIVE_TEST=1` is set, and
///   - Accessibility (AXIsProcessTrusted) is granted to the test runner.
///
/// #221 DISCIPLINE (CRITICAL): this test NEVER issues a `whose content contains`
/// AppleScript scan — that O(corpus) full-body load OOM-crashes Mail on a large
/// mailbox. The source message is found by metadata only (`first message of
/// inbox`), and draft cleanup is an id-DELTA over the (small) drafts mailbox —
/// only the draft we just created is deleted, identified by id, never by body.
final class ReplyPasteLiveTests: XCTestCase {

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
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A real message to reply to, found by METADATA ONLY (no content scan, #221).
    /// Returns nil if the inbox is empty or the lookup fails (→ test skips).
    private func firstInboxMessage() -> (id: String, mailbox: String, account: String)? {
        let raw = runOsa("""
        tell application "Mail"
            try
                set m to (first message of inbox)
                set mb to mailbox of m
                return (id of m as string) & "|" & (name of mb) & "|" & (name of account of mb)
            on error
                return ""
            end try
        end tell
        """)
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// Resolve the source account's REAL drafts mailbox. The unified `drafts
    /// mailbox` smart-view enumerates fine but RESISTS a filtered `delete` (a
    /// `delete m` on a smart-view message silently fails), and the `drafts mailbox
    /// of account` accessor errors on this setup — so we iterate the account's own
    /// mailboxes and pick the drafts one by a best-effort name match. AppleScript
    /// snippet (interpolate the escaped account name + assign `_db`).
    private func resolveAccountDraftsSnippet(_ account: String) -> String {
        let esc = account.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        return """
                set _db to missing value
                try
                    repeat with mb in (mailboxes of account "\(esc)")
                        if (name of mb) is "Drafts" or (name of mb) contains "Draft" or (name of mb) contains "草稿" then set _db to mb
                    end repeat
                end try
        """
    }

    /// Snapshot the ids of every message in the source account's real drafts
    /// mailbox. Drafts are few, so enumerating ids is cheap and — crucially —
    /// reads NO message body (#221-safe). Returns nil on failure so cleanup can
    /// refuse to run rather than risk a too-broad delete.
    private func draftMessageIds(account: String) -> Set<String>? {
        let raw = runOsa("""
        tell application "Mail"
        \(resolveAccountDraftsSnippet(account))
            if _db is missing value then return "ERR"
            set _ids to {}
            try
                repeat with m in (messages of _db)
                    set end of _ids to (id of m as string)
                end repeat
            on error
                return "ERR"
            end try
            set AppleScript's text item delimiters to ","
            return _ids as string
        end tell
        """)
        if raw == "ERR" { return nil }
        if raw.isEmpty { return [] }
        return Set(raw.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// Delete ONLY drafts whose id is not in `before` — the one(s) this test just
    /// created — from the source account's real drafts mailbox (where `delete`
    /// actually works). id-delta cleanup: never touches a pre-existing user draft,
    /// and never scans bodies (#221). No-op if `before` is nil (snapshot failed).
    private func deleteNewDrafts(account: String, notIn before: Set<String>?) {
        guard let before = before else { return }   // snapshot failed → refuse to delete
        let beforeList = "{" + before.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        _ = runOsa("""
        tell application "Mail"
        \(resolveAccountDraftsSnippet(account))
            if _db is missing value then return
            set _before to \(beforeList)
            try
                repeat with m in (messages of _db)
                    set _mid to (id of m as string)
                    if _mid is not in _before then
                        try
                            delete m
                        end try
                    end if
                end repeat
            end try
        end tell
        """)
    }

    /// grep -rl for an .emlx under ~/Library/Mail containing `needle`, polling up
    /// to ~15s for Mail to materialize the saved draft. This is a FILESYSTEM grep
    /// (read-only, off Mail's process) — NOT an AppleScript content scan, so it
    /// does not load message bodies into Mail (#221-safe).
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

    func testLive_replyEmail_pastePath_newBodyWrapperFree_quoteRetained() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHE_MAIL_LIVE_TEST"] == "1",
                          "live test — set CHE_MAIL_LIVE_TEST=1 to run")
        try XCTSkipUnless(AccessibilityStatus.isTrusted,
                          "live test needs Accessibility granted to the test runner")

        guard let src = firstInboxMessage() else {
            throw XCTSkip("no inbox message available to reply to")
        }

        let marker = "LIVEREPLY218_\(Int(Date().timeIntervalSince1970))"
        // id-delta cleanup on the source account's real drafts mailbox: only the
        // draft we create gets deleted (never a content scan). The clean path
        // closes its draft window after ⌘S, so the draft isn't window-locked.
        let draftsBefore = draftMessageIds(account: src.account)
        defer { deleteNewDrafts(account: src.account, notIn: draftsBefore) }

        let result = try await MailController.shared.replyEmail(
            id: src.id,
            mailbox: src.mailbox,
            accountName: src.account,
            body: "新本文第一行 \(marker)\n第二行：應在引用之上、不被 cite 包住",
            saveAsDraft: true
        )

        // (a) the clean paste branch returns a distinct success string; reaching it
        // proves the GUI chain ran without throwing (else → legacy fallback string).
        XCTAssertTrue(result.contains("(paste path)"),
                      "expected clean reply paste path, got: \(result)")

        // (b) the ACTUAL #218 regression assertions: read the saved draft .emlx.
        guard let emlx = findDraftEmlx(containing: marker) else {
            XCTFail("saved reply draft .emlx not found on disk for marker \(marker)")
            return
        }
        let raw = (try? String(contentsOfFile: emlx, encoding: .utf8)) ?? ""
        // The saved HTML part is QUOTED-PRINTABLE encoded: literal `=` is stored as
        // `=3D` and long lines are soft-wrapped with a trailing `=` + newline. So a
        // raw `.contains("blockquote type=\"cite\"")` would miss the tag even when
        // it IS present (it's stored as `type=3D"cite"`, split across a soft wrap).
        // Undo just those two transforms so the structural ASCII tags + the ASCII
        // marker are contiguous + matchable (the CJK body stays QP-encoded — we
        // don't need it decoded, only the marker and the tags).
        let body = raw
            .replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
            .replacingOccurrences(of: "=3D", with: "=")
            .replacingOccurrences(of: "=3d", with: "=")

        // The #218 wrapper signature must be ABSENT — the clean path never emits it.
        XCTAssertFalse(body.contains("Apple-Mail-URLShareWrapperClass"),
                       "reply NEW body must NOT carry the URLShare/cite wrapper (#218): \(emlx)")
        // Mail's native quoted original must still be present (we kept the quote).
        XCTAssertTrue(body.contains("blockquote type=\"cite\""),
                      "native quoted original (cite-blockquote) must be present: \(emlx)")
        // The NEW body must sit ABOVE the quote — its marker precedes the first
        // cite-blockquote. The legacy bug would put the new body INSIDE the wrapper.
        if let mIdx = body.range(of: marker),
           let qIdx = body.range(of: "blockquote type=\"cite\"") {
            XCTAssertLessThan(mIdx.lowerBound, qIdx.lowerBound,
                              "new body must appear ABOVE the native quote, not wrapped inside it")
        } else {
            XCTFail("could not locate both the marker and a cite-blockquote in the saved body")
        }
    }
}
