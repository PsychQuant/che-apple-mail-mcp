import Foundation

/// #464 — opt-in per-step timing of the GUI compose path, written as CSV.
///
/// End-to-end numbers could not say which wait mattered: lowering the env
/// delays showed the 1.8 s window wait could drop to 0.2 s with the draft still
/// correct, while a 0 s step delay failed the sender read-back. Timing each step
/// answers that directly, and gives users a way to report where a slow call
/// spent its time.
///
/// Enabled only when `CHE_MAIL_COMPOSE_TIMING_CSV` names a file. The generated
/// AppleScript then starts with an ASObjC prelude and logs one
/// `CHE_MAIL_TIMING|<step>|<NSDate reference seconds>` line per step to
/// osascript's stderr (the transport already tolerates `log` noise there,
/// #301). The Swift side adds its own marks and appends one CSV row per mark.
/// With the variable unset the script is byte-for-byte what it was.
enum ComposeTiming {
    static let envKey = "CHE_MAIL_COMPOSE_TIMING_CSV"
    static let logPrefix = "CHE_MAIL_TIMING|"

    static var csvPathFromEnvironment: String? {
        guard let path = ProcessInfo.processInfo.environment[envKey], !path.isEmpty else { return nil }
        return path
    }

    static var isEnabled: Bool { csvPathFromEnvironment != nil }

    /// Must be the first statements of the script: `use` clauses precede
    /// everything, and `use scripting additions` keeps `delay` working once a
    /// framework is imported. Reference-date seconds are logged as a real; an
    /// AppleScript integer (30-bit) cannot hold them in milliseconds.
    static let prelude = """
    use framework "Foundation"
    use scripting additions
    on _cheMailMark(_label)
        log "\(logPrefix)" & _label & "|" & ((current application's NSDate's timeIntervalSinceReferenceDate()) as text)
    end _cheMailMark

    """

    static func markStatement(_ label: String) -> String {
        "my _cheMailMark(\"\(label)\")"
    }

    struct Mark: Equatable {
        let source: String
        let label: String
        /// Seconds since the NSDate reference date (2001-01-01 UTC).
        let time: TimeInterval
    }

    static func parseMarks(fromStderr text: String) -> [Mark] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(logPrefix) else { return nil }
            let fields = line.dropFirst(logPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty,
                  let seconds = Double(fields[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
            return Mark(source: "script", label: String(fields[0]), time: seconds)
        }
    }

    static let csvHeader =
        "run_id,source,step,t_ref,ms_since_start,ms_since_prev,outcome,window_delay,step_delay,from_address_set"

    static func csvRows(runId: String, marks: [Mark], outcome: String, config: [String: String]) -> [String] {
        let sorted = marks.sorted { $0.time < $1.time }
        guard let start = sorted.first?.time else { return [] }
        let tail = ["window_delay", "step_delay", "from_address_set"].map { config[$0] ?? "" }
        var previous = start
        return sorted.map { mark in
            let sinceStart = Int(((mark.time - start) * 1000).rounded())
            let sincePrev = Int(((mark.time - previous) * 1000).rounded())
            previous = mark.time
            return ([runId, mark.source, mark.label, String(format: "%.3f", mark.time),
                     String(sinceStart), String(sincePrev), outcome] + tail).joined(separator: ",")
        }
    }

    static func append(rows: [String], toCSVAt path: String) throws {
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: path)
            || ((try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0) == 0
        if isNew { fm.createFile(atPath: path, contents: nil) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        let text = (isNew ? [csvHeader] : []) + rows
        try handle.write(contentsOf: Data((text.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - Hand-off from the osascript transport to composeViaMailto

    private static let lock = NSLock()
    private static var captured: [Mark] = []

    /// Called by the transport with osascript's stderr (success or failure).
    static func captureStderr(_ text: String) {
        let marks = parseMarks(fromStderr: text)
        guard !marks.isEmpty else { return }
        lock.lock(); captured.append(contentsOf: marks); lock.unlock()
    }

    static func takeCapturedMarks() -> [Mark] {
        lock.lock(); defer { lock.unlock() }
        let marks = captured
        captured = []
        return marks
    }
}
