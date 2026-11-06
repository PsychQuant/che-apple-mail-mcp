import Foundation

/// #465 — a log category that is safe to splice into a `--predicate` string.
///
/// The predicate is the one place caller-influenced text meets a string that
/// another program parses. A plain `String` cannot say "already validated", so
/// a later caller could pass raw text through by accident; this type can only
/// be built through the check, which makes the unsafe call a type error rather
/// than a code-review catch.
struct LogCategoryToken: Equatable {
    let value: String

    /// `\A…\z`, not `^…$`: `$` also matches before a trailing newline, which would let
    /// "Drafts\n" through into the predicate string (verify round 1, findings #27/#33).
    private static let allowed = try! NSRegularExpression(pattern: #"\A[A-Za-z0-9_.\-]{1,64}\z"#)

    init?(_ text: String) {
        let range = NSRange(text.startIndex..., in: text)
        guard Self.allowed.firstMatch(in: text, range: range) != nil else { return nil }
        self.value = text
    }
}

/// What to read: a closed time window and optional category filter. No free
/// text — `contains` is applied in-process by the service, never here.
struct LogReadRequest: Equatable {
    let start: Date
    let end: Date
    let categories: [LogCategoryToken]
}

/// Why a read finished. `exhausted` means the reader reached end of output on
/// its own; everything else is a deliberate or forced stop.
enum LogReadEnd: Equatable {
    case exhausted(exitStatus: Int32, stderrTail: String)
    case stoppedByHandler
    case scanCap
    case deadline
    case spawnFailed(String)
    /// The client cancelled the call (#467).
    case cancelled
}

/// Seam between the service and whatever produces ndjson lines. Production is
/// `LogShowRunner`; tests inject a fake. Keeping it this narrow is also what
/// makes a later `OSLogStore` implementation a swap, not a rewrite (design:
/// the read path is reversible).
protocol LogEventSource {
    /// Streams raw ndjson lines (no trailing newline) to `onLine` until it
    /// returns `false`, the source ends, or a bound is hit.
    func read(_ request: LogReadRequest, onLine: (Data) -> Bool) -> LogReadEnd

    /// The same, stopping with `.cancelled` once `cancellation` is set (#467).
    func read(_ request: LogReadRequest, cancellation: LogReadCancellation,
              onLine: (Data) -> Bool) -> LogReadEnd
}

extension LogEventSource {
    /// For a source with nothing to wait on: it stops at the next line. A
    /// source that can sit silently, as `LogShowRunner` can behind a quiet
    /// child, must implement this itself.
    func read(_ request: LogReadRequest, cancellation: LogReadCancellation,
              onLine: (Data) -> Bool) -> LogReadEnd {
        if cancellation.isCancelled { return .cancelled }
        var cancelled = false
        let end = read(request) { line in
            if cancellation.isCancelled { cancelled = true; return false }
            return onLine(line)
        }
        return cancelled ? .cancelled : end
    }
}
