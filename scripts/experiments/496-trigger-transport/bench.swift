// #496 — how the ~198 ms between `trigger_spawn` and `trigger_script_start`
// (#489, timing on) splits up, and what an in-process transport would cost.
//
// Read-only: no drafts are created. The only Apple event sent is
// `tell application "Mail" to get name`. Before any Apple event the harness runs
// the same Automation pre-flight the server runs and exits if permission is not
// already granted, so it can never raise a consent prompt.
//
// Build and run (see README.md):
//   swiftc -O -o /tmp/bench496 scripts/experiments/496-trigger-transport/bench.swift
//   /tmp/bench496 30 scripts/experiments/496-trigger-transport/results.json
import AppKit
import Carbon
import Foundation

// MARK: - Conditions

// Copied verbatim from Sources/CheAppleMailMCP/AppleScript/ComposeTiming.swift
// (`prelude`, `logPrefix`) so condition (d) loads exactly what timing-on loads.
let logPrefix = "CHE_MAIL_TIMING|"
let prelude = """
use framework "Foundation"
use scripting additions
on _cheMailMark(_label)
    log "\(logPrefix)" & _label & "|" & ((current application's NSDate's timeIntervalSinceReferenceDate()) as text)
end _cheMailMark

"""
let mailScript = "tell application \"Mail\" to get name"

enum Condition: String, CaseIterable {
    case a_probe, b_spawn_return1, c_spawn_mail, d_spawn_prelude_mail, e_inproc_compile_mail, f_inproc_precompiled_mail
}

// MARK: - Automation pre-flight (same calls as AutomationStatus.probe)

func probe() -> OSStatus? {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else { return nil }
    var addr = AEAddressDesc()
    let id = "com.apple.mail"
    let err = id.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &addr) }
    guard err == noErr else { return OSStatus(err) }
    defer { AEDisposeDesc(&addr) }
    return AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, false)
}

// MARK: - Subprocess transport (shape of MailController.runSubprocessScript)

final class Box: @unchecked Sendable { var data = Data() }

/// Returns (wall ms, stderr text, spawn instant as NSDate reference seconds).
func runOsascript(_ source: String, expect: String) throws -> (ms: Double, stderr: String, spawnRef: Double) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-"]
    var env = ProcessInfo.processInfo.environment
    env["LANG"] = "en_US.UTF-8"
    process.environment = env
    let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let spawnRef = Date().timeIntervalSinceReferenceDate
    let start = DispatchTime.now().uptimeNanoseconds
    try process.run()
    let out = Box(), err = Box(), group = DispatchGroup()
    group.enter()
    Thread.detachNewThread { out.data = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data(); group.leave() }
    group.enter()
    Thread.detachNewThread { err.data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data(); group.leave() }
    try stdinPipe.fileHandleForWriting.write(contentsOf: Data(source.utf8))
    try stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    guard group.wait(timeout: .now() + 20) == .success else { throw BenchError.drainTimeout }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    guard process.terminationStatus == 0 else {
        throw BenchError.scriptFailed(String(decoding: err.data, as: UTF8.self))
    }
    let stdout = String(decoding: out.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard stdout == expect else { throw BenchError.scriptFailed("expected \(expect), got \(stdout)") }
    return (ms, String(decoding: err.data, as: UTF8.self), spawnRef)
}

// MARK: - In-process transport (shape of MailController.runScript + runGuarded)

/// Runs `body` on a detached thread and waits, as runGuarded does.
func onDetachedThread(_ body: @escaping @Sendable () -> Void) throws -> Double {
    let done = DispatchSemaphore(value: 0)
    let start = DispatchTime.now().uptimeNanoseconds
    Thread.detachNewThread { body(); done.signal() }
    guard done.wait(timeout: .now() + 20) == .success else { throw BenchError.inProcessTimeout }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

final class ScriptBox: @unchecked Sendable { let script: NSAppleScript; init(_ s: NSAppleScript) { script = s } }

/// Every in-process run must actually reach Mail: a failed execution returns
/// fast and would otherwise pass for a fast transport.
final class Outcome: @unchecked Sendable { var ok = false }
func executeChecked(_ script: NSAppleScript, _ outcome: Outcome) {
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    outcome.ok = error == nil && result.stringValue == "Mail"
}

enum BenchError: Error { case drainTimeout, inProcessTimeout, scriptFailed(String), notGranted(String) }

// MARK: - Main

let args = CommandLine.arguments
let n = args.count > 1 ? Int(args[1]) ?? 30 : 30
let outPath = args.count > 2 ? args[2] : "results.json"
let warmup = 3

/// 1-minute load average. Timings below are wall-clock, so a busy machine
/// inflates them; the value is recorded with each run.
func loadAverage() -> Double { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0] }
let loadAtStart = loadAverage()

guard let status = probe() else {
    FileHandle.standardError.write(Data("Mail is not running; start Mail and retry.\n".utf8)); exit(2)
}
guard status == noErr else {
    FileHandle.standardError.write(Data("Automation for Mail is not granted (status \(status)); not sending any Apple event.\n".utf8)); exit(2)
}

// #471: initialize the AppleScript component on the main thread before any
// background use, exactly as AppleScriptPrimer does in the server.
_ = NSAppleScript(source: "return 1")?.executeAndReturnError(nil)

let precompiled = NSAppleScript(source: mailScript)!
var compileError: NSDictionary?
precompiled.compileAndReturnError(&compileError)
let precompiledBox = ScriptBox(precompiled)

var samples: [String: [Double]] = [:]
var spawnToMark: [Double] = []
// The pre-flight's own result, per call. A non-zero status is recorded, not
// fatal: permission was confirmed granted before the first Apple event, so a
// later blip cannot raise a consent prompt.
var probeStatuses: [String: Int] = [:]
var rng = SystemRandomNumberGenerator()

func measure(_ c: Condition) throws -> Double {
    switch c {
    case .a_probe:
        let start = DispatchTime.now().uptimeNanoseconds
        let status = probe()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        probeStatuses[status.map { "\($0)" } ?? "mail_not_running", default: 0] += 1
        return ms
    case .b_spawn_return1:
        return try runOsascript("return 1", expect: "1").ms
    case .c_spawn_mail:
        return try runOsascript(mailScript, expect: "Mail").ms
    case .d_spawn_prelude_mail:
        let r = try runOsascript(prelude + "my _cheMailMark(\"bench\")\n" + mailScript, expect: "Mail")
        if let line = r.stderr.split(separator: "\n").first(where: { $0.contains(logPrefix) }),
           let t = Double(line.split(separator: "|").last!.replacingOccurrences(of: ",", with: ".")) {
            spawnToMark.append((t - r.spawnRef) * 1000)
        }
        return r.ms
    case .e_inproc_compile_mail:
        let outcome = Outcome()
        let ms = try onDetachedThread { executeChecked(NSAppleScript(source: mailScript)!, outcome) }
        guard outcome.ok else { throw BenchError.scriptFailed("in-process (e) did not return Mail") }
        return ms
    case .f_inproc_precompiled_mail:
        let outcome = Outcome()
        let ms = try onDetachedThread { executeChecked(precompiledBox.script, outcome) }
        guard outcome.ok else { throw BenchError.scriptFailed("in-process (f) did not return Mail") }
        return ms
    }
}

do {
    for round in 0..<(warmup + n) {
        for c in Condition.allCases.shuffled(using: &rng) {
            let ms = try measure(c)
            if round >= warmup { samples[c.rawValue, default: []].append(ms) }
        }
    }
    if spawnToMark.count > n { spawnToMark.removeFirst(spawnToMark.count - n) }  // drop warm-up rounds
} catch {
    FileHandle.standardError.write(Data("bench failed: \(error)\n".utf8)); exit(1)
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

let osv = ProcessInfo.processInfo.operatingSystemVersion
let mailVersion = (NSDictionary(contentsOfFile: "/System/Applications/Mail.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? "?"
let report: [String: Any] = [
    "meta": ["n": n, "warmup_rounds_discarded": warmup, "macos": "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)",
             "mail": mailVersion, "date": ISO8601DateFormatter().string(from: Date()),
             "load_avg_1m_start": loadAtStart, "load_avg_1m_end": loadAverage()],
    "samples_ms": samples,
    "d_spawn_to_first_mark_ms": spawnToMark,
    "a_probe_statuses_including_warmup": probeStatuses,
    "summary_ms": samples.mapValues { ["median": median($0), "min": $0.min()!, "max": $0.max()!] }
        .merging(["d_spawn_to_first_mark": ["median": median(spawnToMark), "min": spawnToMark.min()!, "max": spawnToMark.max()!]]) { a, _ in a },
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: outPath))
for key in (report["summary_ms"] as! [String: [String: Double]]).keys.sorted() {
    let s = (report["summary_ms"] as! [String: [String: Double]])[key]!
    print(String(format: "%-28@ median %7.1f ms  (%.1f–%.1f)", key as NSString, s["median"]!, s["min"]!, s["max"]!))
}
