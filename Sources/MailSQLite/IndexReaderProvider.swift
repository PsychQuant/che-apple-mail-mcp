import Foundation

/// Hands out the server's `EnvelopeIndexReader`, and keeps trying to open it
/// when the first attempt failed (#537).
///
/// The server used to build the reader once, in `init`. A refusal at that
/// moment (a TCC denial that clears a minute later, a launch-time hiccup) made
/// every read tool use the AppleScript fallback for the rest of the process,
/// while `check_fda` — which only `fopen`s the file — reported "GRANTED". A
/// missing reader is now a state the provider can leave:
///
/// - `current()` returns the reader if there is one. If there is none and the
///   last attempt is at least `retryInterval` old, it tries to open it again,
///   under the lock, so any number of callers racing for the retry share one
///   open and one result (no second connection that nobody closes).
/// - `forceRetry()` is the explicit path (`check_fda`): it ignores the interval
///   and says what happened.
///
/// "Not a permanent verdict" also means "not a flood": a failure that repeats
/// unchanged is logged once, because a Mail-less (EWS-only) setup fails the
/// same way every interval for as long as the server lives.
///
/// What counts as "opened" is decided by `open`; the provider only caches its
/// result. The open action, the clock, the FDA probe and the log sink are all
/// injected, so tests need no Mail data and no real time.
///
/// Concurrency: one `NSLock` guards the state. The API is synchronous and no
/// caller holds the lock across a suspension point.
public final class IndexReaderProvider: @unchecked Sendable {

    /// Seconds between automatic retries. A setup without Mail pays one `stat`
    /// plus one failed open per interval, and only while read tools are in use.
    public static let defaultRetryInterval: TimeInterval = 30

    /// What `forceRetry()` found.
    public enum RetryOutcome: Equatable {
        /// There was already a reader; nothing was reopened.
        case alreadyAvailable
        /// There was no reader and the open just succeeded. `priorFailure` is
        /// the error of the failure it recovered from, when one is known.
        case recovered(priorFailure: String?)
        /// There was no reader and the open failed again, with this error.
        case stillUnavailable(String)
    }

    private enum Trigger {
        case startup   // the first attempt, made when the server starts
        case lazy      // a read tool asked and the interval had passed
        case forced    // `forceRetry()`
    }

    private let retryInterval: TimeInterval
    private let open: () throws -> EnvelopeIndexReader
    private let uptime: () -> TimeInterval
    private let probe: () -> FDAStatus.Detail
    private let log: (String) -> Void

    private let lock = NSLock()
    private var reader: EnvelopeIndexReader?
    private var lastAttempt: TimeInterval?
    /// Error of the most recent failed attempt; cleared by a success.
    private var lastFailure: String?
    /// Message plus probe result of the last failure that was written to the
    /// log, so an unchanged repeat can be skipped.
    private var lastLoggedFailureKey: String?

    /// - Parameters:
    ///   - retryInterval: minimum seconds between automatic attempts.
    ///   - open: makes one attempt to build the reader.
    ///   - uptime: a monotonic clock in seconds.
    ///   - probe: the FDA read probe, recorded next to every failure so a later
    ///     reader can tell whether the probe and the SQLite open agreed.
    ///   - log: receives complete log lines (the caller routes them to stderr).
    public init(
        retryInterval: TimeInterval = IndexReaderProvider.defaultRetryInterval,
        open: @escaping () throws -> EnvelopeIndexReader,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        probe: @escaping () -> FDAStatus.Detail = { FDAStatus.probeDetail() },
        log: @escaping (String) -> Void
    ) {
        self.retryInterval = retryInterval
        self.open = open
        self.uptime = uptime
        self.probe = probe
        self.log = log
    }

    /// The reader, or `nil` while there is none. Retries the open when the last
    /// attempt is at least `retryInterval` old; the first call is the startup
    /// attempt and is always made.
    public func current() -> EnvelopeIndexReader? {
        lock.lock()
        defer { lock.unlock() }
        if let reader = reader { return reader }
        let now = uptime()
        if let last = lastAttempt, now - last < retryInterval { return nil }
        _ = attempt(at: now, trigger: lastAttempt == nil ? .startup : .lazy)
        return reader
    }

    /// Try to open the reader now, whatever the interval says. The next
    /// automatic retry counts from this moment.
    public func forceRetry() -> RetryOutcome {
        lock.lock()
        defer { lock.unlock() }
        if reader != nil { return .alreadyAvailable }
        return attempt(at: uptime(), trigger: .forced)
    }

    // MARK: - one attempt (lock held)

    private func attempt(at now: TimeInterval, trigger: Trigger) -> RetryOutcome {
        lastAttempt = now
        do {
            let opened = try open()
            reader = opened
            let prior = lastFailure
            lastFailure = nil
            lastLoggedFailureKey = nil
            if trigger == .startup { return .alreadyAvailable }
            log(Self.recoveredLine(prior: prior, trigger: trigger, probe: probe()))
            return .recovered(priorFailure: prior)
        } catch {
            let message = error.localizedDescription
            let detail = probe()
            let key = message + "\n" + detail.logText
            lastFailure = message
            // A lazy retry that fails exactly as before adds nothing. The
            // startup failure and every explicit check are always written.
            if trigger != .lazy || key != lastLoggedFailureKey {
                lastLoggedFailureKey = key
                log(failureLine(message: message, trigger: trigger, probe: detail))
            }
            return .stillUnavailable(message)
        }
    }

    // MARK: - log lines

    private func failureLine(message: String, trigger: Trigger, probe: FDAStatus.Detail) -> String {
        switch trigger {
        case .startup:
            // The prefix and the fallback explanation are the documented startup
            // message (README, "Diagnosing fast-path bypass"); the retry sentence
            // is new with #537.
            return "EnvelopeIndexReader init failed: \(message)\n"
                + "Read tools will use the AppleScript fallback path (slower; expected for "
                + "EWS-only accounts, see README) until the index can be opened. The server "
                + "retries when a read tool runs, at most once every \(Int(retryInterval)) s, "
                + "and check_fda retries at once. For local IMAP/POP accounts this usually "
                + "means Full Disk Access is missing — see the actionable steps above.\n"
                + "\(probe.logText)\n"
        case .lazy:
            return "EnvelopeIndexReader retry failed: \(message)\n\(probe.logText)\n"
        case .forced:
            return "EnvelopeIndexReader retry failed (requested by check_fda): \(message)\n\(probe.logText)\n"
        }
    }

    private static func recoveredLine(prior: String?, trigger: Trigger, probe: FDAStatus.Detail) -> String {
        let source = trigger == .forced ? " (requested by check_fda)" : ""
        let earlier = prior.map { " after: \(firstLine($0))" } ?? ""
        return "EnvelopeIndexReader retry recovered\(source)\(earlier). "
            + "Read tools use the SQLite fast path again.\n\(probe.logText)\n"
    }

    /// The first line of a possibly multi-line error text.
    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
    }
}
