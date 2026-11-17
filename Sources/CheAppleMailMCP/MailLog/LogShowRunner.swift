import Darwin
import Foundation

/// #465 — reads `log show --style ndjson` as a bounded subprocess.
///
/// Every bound exists because the output is attacker-adjacent and large: an
/// hour of Mail's logs is ~90 MB, and parts of it (message arguments) derive
/// from mail content. So: absolute executable path, argument array (no shell),
/// stdin closed, line-by-line streaming (never the whole output in memory),
/// a byte cap, a wall-clock deadline, and the child's whole process group is always
/// signalled and the child reaped once we stop reading (#646).
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
        read(request, cancellation: LogReadCancellation(), onLine: onLine)
    }

    func read(_ request: LogReadRequest, cancellation: LogReadCancellation,
              onLine: (Data) -> Bool) -> LogReadEnd {
        if cancellation.isCancelled { return .cancelled }
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        let child: SpawnedChild
        do {
            child = try SpawnedChild.spawn(executablePath: executableURL.path,
                                           arguments: makeArguments(request),
                                           environment: environment)
        } catch {
            let why = (error as? SpawnFailure)?.message ?? error.localizedDescription
            return .spawnFailed("could not launch \(executableURL.path): \(why)")
        }

        let tail = TailBuffer(limit: Self.stderrTailBytes)
        let stderrDone = DispatchSemaphore(value: 0)
        let stderrFD = child.stderrFD
        Self.liveStderrReaderCounter.increment()
        Thread.detachNewThread {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(stderrFD, &chunk, chunk.count)
                if n > 0 { tail.append(Data(chunk[0..<n])); continue }
                if n < 0, errno == EINTR { continue }
                break
            }
            // The reader owns the descriptor and closes it itself, after its last read: closing it from the
            // calling thread while a read is still blocked (a descendant can hold the pipe open past any
            // wait) would let the number be reused by the next call's pipe (verify round 3, 14; round 4, 11/15).
            close(stderrFD)
            Self.liveStderrReaderCounter.decrement()
            stderrDone.signal()
        }

        let stopped = pump(fd: child.stdoutFD, cancellation: cancellation, onLine: onLine)

        let end: LogReadEnd
        if let stopped {
            _ = Self.stopGroup(child)
            end = stopped
        } else {
            // Natural EOF. The leader should be exiting; bound the wait anyway. It is observed, not
            // reaped, so its group number stays ours while we signal (#646).
            let status: Int32
            if child.waitForExit(timeout: 5) {
                let stderrFinished = stderrDone.wait(timeout: .now() + 2) == .success
                // A descendant may still hold stderr, or hold nothing and simply linger. The leader is a
                // zombie, so the group number cannot have been reused: signal, then reap.
                child.signalGroup(SIGKILL)
                if !stderrFinished { _ = stderrDone.wait(timeout: .now() + 2) }
                status = child.reap(waitingUpTo: 2)
            } else {
                status = Self.stopGroup(child)
                _ = stderrDone.wait(timeout: .now() + 2)
            }
            end = .exhausted(exitStatus: status,
                             stderrTail: String(decoding: tail.snapshot(), as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        close(child.stdoutFD)
        return end
    }

    /// Streams lines until the handler stops, a cap or the deadline is hit, or
    /// EOF. Returns the forced-stop reason, or `nil` for a natural EOF.
    private func pump(fd: Int32, cancellation: LogReadCancellation,
                      onLine: (Data) -> Bool) -> LogReadEnd? {
        let deadlineAt = Date().addingTimeInterval(deadline)
        var pending = Data()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)

        while true {
            // Checked every slice, so a cancel reaches a silent child within one
            // poll slice; the caller then terminates and reaps it (#467).
            if cancellation.isCancelled { return .cancelled }
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

    /// #646 — SIGTERM to the whole group, a short grace for the leader, then SIGKILL to the group
    /// (it sweeps whatever ignored SIGTERM), and only then reap. Both signals go out while the leader
    /// is unreaped, so the group number cannot belong to anyone else. Returns the leader's status,
    /// or -1 for one that could not be reaped.
    private static func stopGroup(_ child: SpawnedChild) -> Int32 {
        child.signalGroup(SIGTERM)
        _ = child.waitForExit(timeout: 2)
        child.signalGroup(SIGKILL)
        return child.reap(waitingUpTo: 2)
    }

    // MARK: - Test seam

    /// Stderr reader threads that have started and not yet closed their descriptor. A reader that a
    /// descendant keeps blocked shows here; a read that returned has none left.
    static var liveStderrReaders: Int { liveStderrReaderCounter.value }
    private static let liveStderrReaderCounter = LiveCounter()
}

private final class LiveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func decrement() { lock.lock(); count -= 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
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
