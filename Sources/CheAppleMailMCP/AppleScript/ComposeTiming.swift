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

    /// #475 added `path` as the last column (`gui-mailto` / `direct`), so the
    /// two `create_draft` paths can be told apart in one file.
    static let csvHeader =
        "run_id,source,step,t_ref,ms_since_start,ms_since_prev,outcome,window_delay,step_delay,from_address_set,path"

    static let guiMailtoPath = "gui-mailto"
    static let directPath = "direct"

    enum AppendError: LocalizedError, CustomStringConvertible {
        /// The file was started by another layout (e.g. #464's 10 columns).
        /// Appending would mix layouts and every header-driven reader would
        /// misalign columns without noticing — so nothing is written.
        case headerMismatch(path: String, found: String)
        /// The file could not be opened, locked, inspected or written.
        case io(path: String, reason: String)

        var description: String {
            switch self {
            case .headerMismatch(let path, let found):
                return "header of \(path) does not match the current layout (found \"\(found)\"); "
                    + "point \(ComposeTiming.envKey) at a new file"
            case .io(let path, let reason):
                return "\(path): \(reason)"
            }
        }

        var errorDescription: String? { description }
    }

    /// One path's part of a run: its marks share a `path`, an `outcome` and the
    /// config columns. A `create_draft` that falls back from the direct write to
    /// the GUI path is one run with two segments (#475).
    struct Segment: Equatable {
        let path: String
        let outcome: String
        let config: [String: String]
        let marks: [Mark]
    }

    static func csvRows(runId: String, marks: [Mark], outcome: String, config: [String: String],
                        path: String = guiMailtoPath) -> [String] {
        csvRows(runId: runId, segments: [Segment(path: path, outcome: outcome, config: config, marks: marks)])
    }

    /// All segments' marks in time order, measured from the earliest mark of the
    /// run, so a fallback's total cost reads straight off the last row.
    static func csvRows(runId: String, segments: [Segment]) -> [String] {
        let tagged = segments.flatMap { segment in segment.marks.map { (mark: $0, segment: segment) } }
            .sorted { $0.mark.time < $1.mark.time }
        guard let start = tagged.first?.mark.time else { return [] }
        var previous = start
        return tagged.map { item in
            let sinceStart = Int(((item.mark.time - start) * 1000).rounded())
            let sincePrev = Int(((item.mark.time - previous) * 1000).rounded())
            previous = item.mark.time
            let tail = ["window_delay", "step_delay", "from_address_set"].map { item.segment.config[$0] ?? "" }
            return ([runId, item.mark.source, item.mark.label, String(format: "%.3f", item.mark.time),
                     String(sinceStart), String(sincePrev), item.segment.outcome] + tail + [item.segment.path])
                .map(csvField).joined(separator: ",")
        }
    }

    /// Fields are joined without quoting, so a comma (or line break) in a value —
    /// e.g. an env delay someone wrote as `0.2,0.3` — would shift every column,
    /// and a double quote would make a standard CSV reader treat it as a field
    /// delimiter (#475 verify R1).
    static func csvField(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// Serializes writers: an in-process lock for concurrent tool calls (the MCP
    /// server runs each request in its own Task), `flock` for another server
    /// process sharing the file, and `O_APPEND` so every write lands at the end.
    /// The existence/header check and the write happen under both locks — before
    /// #475 verify R1 a second writer could `createFile` over the first one's rows.
    private static let appendLock = NSLock()

    static func append(rows: [String], toCSVAt path: String) throws {
        appendLock.lock(); defer { appendLock.unlock() }
        let fd = open(path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw AppendError.io(path: path, reason: "open: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw AppendError.io(path: path, reason: "flock: \(String(cString: strerror(errno)))")
        }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw AppendError.io(path: path, reason: "fstat: \(String(cString: strerror(errno)))")
        }
        let isNew = info.st_size == 0
        if !isNew {
            let first = firstLine(of: fd)
            guard first == csvHeader else { throw AppendError.headerMismatch(path: path, found: first) }
        }
        let data = Data((((isNew ? [csvHeader] : []) + rows).joined(separator: "\n") + "\n").utf8)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AppendError.io(path: path, reason: "write: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    /// Reads only up to the first line break (bounded), never the whole file.
    private static func firstLine(of fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = pread(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return "" }
        let text = String(decoding: buffer[0..<n], as: UTF8.self)
        return String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }

    // MARK: - Runs (#475)

    /// The rows of one composing call. `create_draft` opens a run so that a
    /// direct-write attempt and the GUI path it falls back to share one `run_id`
    /// and one starting point; the run writes everything once, when it ends.
    final class Run: @unchecked Sendable {
        let id = UUID().uuidString
        private let lock = NSLock()
        private var segments: [Segment] = []

        func add(_ segment: Segment) {
            lock.lock(); segments.append(segment); lock.unlock()
        }

        var collected: [Segment] {
            lock.lock(); defer { lock.unlock() }
            return segments
        }
    }

    /// Carried down `create_draft → createDraft → composeViaMailto` on the same
    /// task, so none of those signatures needs a timing parameter.
    @TaskLocal static var currentRun: Run?

    /// Runs `body` inside a run when `csvPath` is set, and writes the run's rows
    /// when it ends — also when `body` throws. With `csvPath` nil this is just `body`.
    static func withRun<T>(csvPath: String?, _ body: () async throws -> T) async rethrows -> T {
        guard let csvPath else { return try await body() }
        let run = Run()
        defer { write(csvRows(runId: run.id, segments: run.collected), to: csvPath) }
        return try await $currentRun.withValue(run) { try await body() }
    }

    /// Inside a run the segment joins it; outside (e.g. `compose_email`) it is
    /// written at once as its own run.
    static func record(_ segment: Segment, csvPath: String) {
        if let run = currentRun {
            run.add(segment)
        } else {
            write(csvRows(runId: UUID().uuidString, segments: [segment]), to: csvPath)
        }
    }

    /// Diagnostics only: a failure goes to stderr and never reaches the compose call.
    private static func write(_ rows: [String], to path: String) {
        guard !rows.isEmpty else { return }
        do {
            try append(rows: rows, toCSVAt: path)
        } catch {
            _ = Diagnostics.emit("compose timing: could not append to \(path): \(error.localizedDescription)\n")
        }
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
