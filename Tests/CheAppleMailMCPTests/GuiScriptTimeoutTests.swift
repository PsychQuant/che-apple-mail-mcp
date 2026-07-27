import XCTest
import Foundation
@testable import CheAppleMailMCP

/// #301 — the 45s uniform script deadline (#297/#298) killed HEALTHY long GUI
/// compose scripts (sender popup / display-name fill on a large mailbox run
/// legitimately past 45s), degrading every such call to the wrapped-body legacy
/// path after ~78s — which the caller experiences as a hang. These tests pin
/// the fix: a per-call timeout that the three GUI-driving call sites raise to
/// `guiScriptTimeout`, while every other script keeps the 45s default, plus an
/// honest two-branch timeout message (the old one blamed TCC even when
/// Automation was verified GRANTED).
final class GuiScriptTimeoutTests: XCTestCase {

    /// The subprocess runner's preflight needs a live Mail process (the
    /// Automation probe refuses to run without a target). The subprocess
    /// behavioral tests themselves never touch Mail — skip them honestly when
    /// Mail isn't running instead of failing on an environment condition.
    private func skipUnlessMailRunning() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        probe.arguments = ["-x", "Mail"]
        try? probe.run(); probe.waitUntilExit()
        if probe.terminationStatus != 0 {
            throw XCTSkip("Mail.app is not running — the Automation preflight needs a live target")
        }
    }

    private func resetSeams() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil)
            sem.signal()
        }
        sem.wait()
    }

    // MARK: - Per-call timeout plumbing

    /// A hanging script bounded by a SHORT per-call timeout must throw
    /// scriptTimedOut quickly — the per-call value, not the 45s default,
    /// governs the wait.
    func testPerCallTimeout_boundsAHangingScript() async {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in Thread.sleep(forTimeInterval: 5); return "late" },
            ineligibility: nil)
        defer { resetSeams() }
        let t0 = Date()
        do {
            _ = try await MailController.shared.runScript("hang", timeout: 0.2)
            XCTFail("a hanging runner must time out")
        } catch let MailError.scriptTimedOut(seconds, _) {
            XCTAssertEqual(seconds, 0, "Int(0.2) — the per-call deadline was used")
        } catch {
            XCTFail("expected scriptTimedOut, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3,
                          "must give up on the per-call deadline, not the 45s default")
    }

    /// The test seam remains the STRONGEST override: a seam-set deadline wins
    /// over a per-call one, so tests can compress any call site's timeout.
    func testSeamOverride_beatsPerCallTimeout() async {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in Thread.sleep(forTimeInterval: 5); return "late" },
            ineligibility: nil, scriptTimeout: 0.2)
        defer { resetSeams() }
        let t0 = Date()
        do {
            // Per-call asks for a LONG deadline; the seam must still win.
            _ = try await MailController.shared.runScript("hang", timeout: 60)
            XCTFail("seam-compressed deadline must fire")
        } catch MailError.scriptTimedOut {
            // expected
        } catch {
            XCTFail("expected scriptTimedOut, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3,
                          "the 0.2s seam deadline governs, not the 60s per-call one")
    }

    /// A fast script under a per-call timeout returns its result unchanged.
    func testPerCallTimeout_doesNotAffectAFastScript() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "quick" }, ineligibility: nil)
        defer { resetSeams() }
        let r = try await MailController.shared.runScript("fast", timeout: 30)
        XCTAssertEqual(r, "quick")
    }

    // MARK: - Deadline constants

    /// The GUI deadline exists, is meaningfully longer than the default (the
    /// live evidence: a healthy sender-popup compose runs past 45s on a large
    /// mailbox), and the default itself is unchanged (#297's contract).
    func testDeadlineConstants() {
        XCTAssertEqual(MailController.defaultScriptTimeout, 45,
                       "#297's default must not change — short scripts keep failing fast")
        XCTAssertGreaterThan(MailController.guiScriptTimeout, 45,
                       "GUI compose flows legitimately exceed the default (#301 live: ~33s worst E2E)")
        XCTAssertLessThan(MailController.guiScriptTimeout, 120,
                       "must stay observable inside the MCP client's ~120s idle window — "
                       + "a deadline the client can't see helps nobody (verify Lens A P1-4)")
    }

    // MARK: - Source guard: the three GUI-driving call sites use runGuiScript

    /// The fix is only real if the LONG GUI scripts actually run on the
    /// osascript subprocess path with the GUI deadline. Pin all three call
    /// sites (clean compose, reply paste, forward paste); every other script
    /// stays on in-process runScript with the 45s default.
    func testGuiCallSites_useRunGuiScriptWithGuiDeadline() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let guiCalls = source.components(separatedBy: "runGuiScript(").count - 1
        // 3 call sites + the declaration itself
        XCTAssertGreaterThanOrEqual(guiCalls, 4,
            "the clean-compose, reply-paste and forward-paste sites must all call "
            + "runGuiScript (osascript subprocess, #301); found \(guiCalls) occurrences")
        let deadlineCalls = source.components(separatedBy: "timeout: Self.guiScriptTimeout").count - 1
        XCTAssertGreaterThanOrEqual(deadlineCalls, 3,
            "all three GUI sites must pass the GUI deadline; found \(deadlineCalls) (#301)")
    }

    // MARK: - osascript subprocess runner (behavioral — real subprocess, no Mail)

    /// Success path: the script's return value comes back without the trailing
    /// newline osascript appends.
    func testRunGuiScript_returnsScriptResult() async throws {
        try skipUnlessMailRunning()
        let r = try await MailController.shared.runGuiScript("return \"gui-ok\"", timeout: 15)
        XCTAssertEqual(r, "gui-ok")
    }

    /// A script error maps onto the SAME MailError.scriptFailed the in-process
    /// path throws — callers and the legacy-fallback routing behave identically.
    func testRunGuiScript_mapsScriptErrorToScriptFailed() async throws {
        try skipUnlessMailRunning()
        do {
            _ = try await MailController.shared.runGuiScript(
                "error \"boom from the gui path\" number -128", timeout: 15)
            XCTFail("script error must throw")
        } catch let MailError.scriptFailed(message, code) {
            XCTAssertEqual(code, -128)
            XCTAssertTrue(message.contains("boom from the gui path"), "got: \(message)")
        } catch {
            XCTFail("expected scriptFailed, got \(error)")
        }
    }

    /// The headline #301 win over the in-process guard: a timed-out subprocess
    /// is REALLY cancelled (terminated), not abandoned — the GUI flow stops
    /// driving Mail the moment the interpreter dies.
    func testRunGuiScript_timeoutTerminatesTheSubprocess() async throws {
        try skipUnlessMailRunning()
        let t0 = Date()
        do {
            _ = try await MailController.shared.runGuiScript("delay 300", timeout: 1)
            XCTFail("a hanging script must time out")
        } catch let MailError.scriptTimedOut(seconds, _) {
            XCTAssertEqual(seconds, 1)
        } catch {
            XCTFail("expected scriptTimedOut, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8,
                          "timeout + terminate must be prompt, not the full delay")
        // The interpreter must be gone: no osascript child still sleeping.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        probe.arguments = ["-f", "osascript"]
        let out = Pipe(); probe.standardOutput = out
        try? probe.run(); probe.waitUntilExit()
        // pgrep may match unrelated osascript processes owned by other apps;
        // assert OUR child died via its delay-300 marker being unfindable is
        // not directly possible — the prompt-return assertion above plus
        // termination in runGuiScript covers the contract.
    }

    /// Seam parity: the fake script runner intercepts runGuiScript exactly like
    /// runScript, so production-site behavioral tests keep working with no
    /// subprocess involved.
    func testRunGuiScript_respectsScriptRunnerSeam() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: { src in "seam:\(src.prefix(6))" }, ineligibility: nil)
        defer { resetSeams() }
        let r = try await MailController.shared.runGuiScript("payload", timeout: 5)
        XCTAssertEqual(r, "seam:payloa")
    }

    /// osascript stderr parsing: the `path: execution error: msg (code)` shape
    /// and the shapeless fallback.
    func testParseOsascriptError() {
        let (m1, c1) = MailController.parseOsascriptError(
            "/dev/stdin: execution error: our window is gone (-1728)")
        XCTAssertEqual(c1, -1728)
        XCTAssertEqual(m1, "our window is gone")
        let (m2, c2) = MailController.parseOsascriptError("garbled output no shape")
        XCTAssertEqual(c2, -1)
        XCTAssertEqual(m2, "garbled output no shape")
        let (m3, c3) = MailController.parseOsascriptError("")
        XCTAssertEqual(c3, -1)
        XCTAssertFalse(m3.isEmpty, "an empty stderr must still yield a message")
    }

    // MARK: - Honest two-branch timeout message

    /// Automation verified GRANTED → the timeout is NOT a TCC problem and the
    /// message must not send the user down the TCC dead end (the #301 live run
    /// hit exactly that: GRANTED probe, yet the error said "usually means
    /// Automation permission is pending" + the full #288 TCC guidance).
    func testTimeoutMessage_grantedBranch_isHonest() throws {
        let msg = try XCTUnwrap(
            MailError.scriptTimedOut(seconds: 120, automationGranted: true).errorDescription)
        XCTAssertFalse(msg.contains("Automation permission is pending"),
                       "GRANTED must not be blamed on TCC; got: \(msg)")
        XCTAssertFalse(msg.contains("tccutil"),
                       "no TCC remediation on the granted branch; got: \(msg)")
        XCTAssertTrue(msg.lowercased().contains("gui") || msg.contains("popup"),
                      "must name the real cause class (long GUI flow); got: \(msg)")
        XCTAssertTrue(msg.contains("still be running") || msg.contains("Mail window"),
                      "must warn the abandoned script may still be driving Mail; got: \(msg)")
        XCTAssertTrue(msg.contains("120"), "must state the deadline that fired")
    }

    /// Automation NOT verified granted → keep the #297 TCC-pending diagnosis +
    /// the #288 guidance (that branch was correct all along).
    func testTimeoutMessage_notGrantedBranch_keepsTccGuidance() throws {
        let msg = try XCTUnwrap(
            MailError.scriptTimedOut(seconds: 45, automationGranted: false).errorDescription)
        XCTAssertTrue(msg.contains("Automation permission is pending"),
                      "not-granted keeps the TCC-pending diagnosis; got: \(msg)")
        XCTAssertTrue(msg.contains("45"), "must state the deadline that fired")
    }

    // MARK: - #301 verify round — parse hardening, sentinel survival, P0 gate, real termination

    /// Extended stderr shapes (verify round): -1743 keeps its code for the
    /// #288 by-code TCC sink; message-final parens don't confuse the code scan;
    /// AppleScript `log` noise keys the parse onto the LAST marker line.
    func testParseOsascriptError_verifyRoundShapes() {
        let (m4, c4) = MailController.parseOsascriptError(
            "/dev/stdin: execution error: Not authorized to send Apple events to Mail. (-1743)")
        XCTAssertEqual(c4, -1743)
        XCTAssertTrue(m4.contains("Not authorized"))
        let (m5, c5) = MailController.parseOsascriptError(
            "/dev/stdin: execution error: POSTDISPATCH: window (main) lost (-1)")
        XCTAssertEqual(c5, -1)
        XCTAssertEqual(m5, "POSTDISPATCH: window (main) lost")
        let (m6, c6) = MailController.parseOsascriptError(
            "warming up\nsome log line\n/dev/stdin: execution error: POSTDISPATCH: keystroke failed (-1728)")
        XCTAssertEqual(c6, -1728)
        XCTAssertEqual(m6, "POSTDISPATCH: keystroke failed")
    }

    /// #242 sentinel survival through the subprocess (verify Lens C P1): a
    /// POSTDISPATCH error travelling osascript-stderr → parse → scriptFailed
    /// must still classify as post-dispatch, or the legacy path re-sends
    /// (duplicate outbound — the #242 disaster class). Includes the shapeless
    /// fallback, which must STILL strip the path prefix.
    func testPostDispatchSentinel_survivesSubprocessErrorPath() {
        let shapes = [
            "/dev/stdin:709:715: execution error: POSTDISPATCH: keystroke failed (-1728)",
            "-:5:20: execution error: POSTDISPATCH: window vanished (-2700)",
            "/dev/stdin: execution error: POSTDISPATCH: dispatch state unknown",
        ]
        for stderr in shapes {
            let (message, code) = MailController.parseOsascriptError(stderr)
            let err = MailError.scriptFailed(message: message, code: code)
            XCTAssertTrue(isPostDispatchError(err),
                          "sentinel lost through subprocess stderr shape: \(stderr) → \(message)")
        }
    }

    /// #301 P0 (verify Lens C): the ONE script spans the ⇧⌘D send keystroke, so
    /// a deadline can expire on either side of it — a timeout on a SENDING flow
    /// is unknown-send-state, not a retryable failure. `.scriptTimedOut` never
    /// carries the sentinel, so it used to sail through `!isPostDispatchError`
    /// into the legacy re-send.
    func testSendFlowTimeout_classifiesAndRefusesFallback() {
        let timeoutErr = MailError.scriptTimedOut(seconds: 120, automationGranted: true)
        XCTAssertTrue(isTimeoutError(timeoutErr))
        XCTAssertFalse(isTimeoutError(MailError.scriptFailed(message: "x", code: -1728)))
        let shouldFallbackSend = { (e: Error) in !isPostDispatchError(e) && !isTimeoutError(e) }
        XCTAssertFalse(shouldFallbackSend(timeoutErr),
                       "a send-flow timeout must NOT fall back to the legacy re-send")
        XCTAssertTrue(shouldFallbackSend(MailError.scriptFailed(message: "pre-dispatch", code: -1719)),
                      "an ordinary pre-dispatch failure keeps the safe fallback")
        let mapped = unknownSendStateError(timeoutErr)
        if case MailError.scriptFailed(let msg, _) = mapped {
            XCTAssertTrue(msg.contains("may or may not"),
                          "timeout wording must not claim the keystroke definitely fired; got: \(msg)")
            XCTAssertTrue(msg.contains("NOT retrying"), "must forbid the retry")
        } else {
            XCTFail("unknownSendStateError must produce scriptFailed")
        }
    }

    /// Gate wiring source guard: all three SEND-capable sites carry the timeout
    /// predicate; createDraft (send:false) deliberately does NOT — a duplicated
    /// draft is harmless, and keeping its fallback is #301's own goal.
    func testSendSites_gateOnTimeout_draftSiteDoesNot() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let composeGate = source.components(
            separatedBy: "!isPostDispatchError($0) && !isTimeoutError($0)").count - 1
        XCTAssertEqual(composeGate, 1, "compose (always-send) gates unconditionally")
        let rfGate = source.components(
            separatedBy: "!isPostDispatchError($0) && !(sendFlow && isTimeoutError($0))").count - 1
        XCTAssertEqual(rfGate, 2, "reply + forward gate on their send condition")
    }

    /// Termination is REAL (verify Lens C P2): promptness alone can't
    /// distinguish kill from abandon (the old #297 guard also returned fast).
    /// The child would write a sentinel file after its delay — prove it never
    /// got there.
    func testRunGuiScript_timeoutActuallyStopsTheChild() async throws {
        try skipUnlessMailRunning()
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("idd301-kill-proof-\(UUID().uuidString)")
        let script = "delay 3\ndo shell script \"touch '\(sentinel.path)'\""
        do {
            _ = try await MailController.shared.runGuiScript(script, timeout: 1)
            XCTFail("must time out")
        } catch MailError.scriptTimedOut {}
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path),
                       "the killed child still executed past its delay — termination is not real")
    }

}
