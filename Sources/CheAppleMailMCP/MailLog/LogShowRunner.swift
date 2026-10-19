import Darwin
import Foundation

/// #465 — reads `log show --style ndjson` as a bounded subprocess.
///
/// Every bound exists because the output is attacker-adjacent and large: an
/// hour of Mail's logs is ~90 MB, and parts of it (message arguments) derive
/// from mail content. So: absolute executable path, argument array (no shell),
/// stdin closed, line-by-line streaming (never the whole output in memory),
/// a byte cap, a wall-clock deadline, and the child is always terminated and
/// reaped once we stop reading.
///
/// Reading is `poll`-sliced rather than "block until EOF". A grandchild that
/// inherits the stdout pipe keeps EOF from ever arriving after we kill the
/// child (the osascript path in `MailController` hit exactly this, #301), so
/// the deadline must be enforced by the loop itself, not by the child's exit.
final class LogShowRunner: LogEventSource {
    private let executableURL: URL
    private let deadline: TimeInterval
    private let scanCapBytes: Int
    private let makeArguments: (LogReadRequest) -> [String]

    /// Last bytes of stderr kept for the `unavailable` report (the caller trims further).
    private static let stderrTailBytes = 2048
    /// A "line" longer than this has no newline in sight — not ndjson; stop.
    private static let maxPartialLineBytes = 4 * 1024 * 1024
    private static let pollSliceMillis: Int32 = 250

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/log"),
         deadline: TimeInterval = 30,
         scanCapBytes: Int = 64 * 1024 * 1024,
         makeArguments: ((LogReadRequest) -> [String])? = nil) {
        self.executableURL = executableURL
        self.deadline = deadline
        self.scanCapBytes = scanCapBytes
        self.makeArguments = makeArguments ?? { LogShowRunner.arguments(for: $0) }
    }

    // MARK: - Arguments

    /// The predicate is fixed text plus `LogCategoryToken`s — nothing a caller
    /// typed ever reaches it. Window edges are widened to whole seconds
    /// (start floors, end ceils) because the CLI takes `YYYY-MM-DD HH:MM:SS`;
    /// widening can only add events at the edges, never drop one.
    static func arguments(for request: LogReadRequest, timeZone: TimeZone = .autoupdatingCurrent) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let start = Date(timeIntervalSince1970: floor(request.start.timeIntervalSince1970))
        // Always the NEXT whole second: `log show --start T --end T` returns nothing (measured), and an
        // `--end` on a whole second leaves that second out — the window is closed at the millisecond, so
        // an event at T.000xxx belongs to it. The service trims to the exact window (verify round 3,
        // findings 3/5/11).
        let end = Date(timeIntervalSince1970: floor(request.end.timeIntervalSince1970) + 1)
        var predicate = #"(subsystem BEGINSWITH "com.apple.mail" OR subsystem BEGINSWITH "com.apple.email")"#
        if !request.categories.isEmpty {
            let clauses = request.categories.map { #"category == "\#($0.value)""# }
            predicate += " AND (" + clauses.joined(separator: " OR ") + ")"
        }
        return ["show", "--style", "ndjson",
                "--start", formatter.string(from: start),
                "--end", formatter.string(from: end),
                "--predicate", predicate]
    }

    // MARK: - Read

    func read(_ request: LogReadRequest, onLine: (Data) -> Bool) -> LogReadEnd {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = makeArguments(request)
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .spawnFailed("could not launch \(executableURL.path): \(error.localizedDescription)")
        }

        let tail = TailBuffer(limit: Self.stderrTailBytes)
        let stderrDone = DispatchSemaphore(value: 0)
        let stderrHandle = stderr.fileHandleForReading
        Thread.detachNewThread {
            while let chunk = try? stderrHandle.read(upToCount: 4096), !chunk.isEmpty {
                tail.append(chunk)
            }
            // The reader owns the descriptor and closes it itself, after its last read: closing it from the
            // calling thread while a read is still blocked (a descendant can hold the pipe open past any
            // wait) would let the number be reused by the next call's pipe (verify round 3, 14; round 4, 11/15).
            try? stderrHandle.close()
            stderrDone.signal()
        }

        let stopped = pump(fd: stdout.fileHandleForReading.fileDescriptor, onLine: onLine)

        let end: LogReadEnd
        if let stopped {
            Self.terminateAndReap(process)
            end = stopped
        } else {
            // Natural EOF. The child should be exiting; bound the wait anyway.
            let status = Self.waitForExit(process, seconds: 5)
            _ = stderrDone.wait(timeout: .now() + 2)
            end = .exhausted(exitStatus: status,
                             stderrTail: String(decoding: tail.snapshot(), as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? stdout.fileHandleForReading.close()
        return end
    }

    /// Streams lines until the handler stops, a cap or the deadline is hit, or
    /// EOF. Returns the forced-stop reason, or `nil` for a natural EOF.
    private func pump(fd: Int32, onLine: (Data) -> Bool) -> LogReadEnd? {
        let deadlineAt = Date().addingTimeInterval(deadline)
        var pending = Data()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)

        while true {
            let remaining = deadlineAt.timeIntervalSinceNow
            if remaining <= 0 { return .deadline }
            let slice = min(Int32(remaining * 1000) + 1, Self.pollSliceMillis)
            let ready = poll(&descriptor, 1, slice)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil   // unreadable pipe: treat as end of stream; exit status tells the story
            }
            if ready == 0 { continue }

            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            if n == 0 {
                // EOF: a final line with no trailing newline still counts.
                if !pending.isEmpty, !onLine(pending) { return .stoppedByHandler }
                return nil
            }
            total += n
            pending.append(buffer, count: n)

            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                let line = pending.subdata(in: lineStart..<newline)
                lineStart = pending.index(after: newline)
                if !onLine(line) { return .stoppedByHandler }
            }
            pending = Data(pending[lineStart...])

            if total > scanCapBytes { return .scanCap }
            if pending.count > Self.maxPartialLineBytes { return .scanCap }
        }
    }

    // MARK: - Process lifecycle

    /// SIGTERM, short grace, then SIGKILL — and always wait, so no zombie.
    private static func terminateAndReap(_ process: Process) {
        if process.isRunning { process.terminate() }
        let exited = DispatchSemaphore(value: 0)
        Thread.detachNewThread { process.waitUntilExit(); exited.signal() }
        if exited.wait(timeout: .now() + 2) == .timedOut {
            // isRunning guards a pid that was reaped (and may be reused) in the gap.
            let pid = process.processIdentifier
            if pid > 0, process.isRunning { kill(pid, SIGKILL) }
            _ = exited.wait(timeout: .now() + 2)
        }
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) -> Int32 {
        let exited = DispatchSemaphore(value: 0)
        Thread.detachNewThread { process.waitUntilExit(); exited.signal() }
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            terminateAndReap(process)
        }
        // `terminationStatus` raises on a process that is still running (an unkillable child).
        return process.isRunning ? -1 : process.terminationStatus
    }
}

/// Keeps only the last `limit` bytes appended, under a lock (two threads touch it).
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data = Data(data.suffix(limit)) }
    }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
