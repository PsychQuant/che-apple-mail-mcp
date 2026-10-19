import Foundation
import MCP

enum MailLogDetail: String, Equatable { case brief, detailed }

/// #465 — a validated `get_mail_log_events` request.
///
/// Everything the tool accepts is checked here, **before** any subprocess is
/// spawned (a bad request must cost nothing). Three rules go beyond range
/// checks because they close silent failures:
///
/// * **Unknown parameters are errors.** A typo such as `contain` would
///   otherwise be dropped and read as "no filter".
/// * **Types are strict.** `"12"` is not an integer, `true` is not a limit.
/// * **`contains` and `redact_identifiers` exist only in `detailed`.** A
///   substring filter on *brief* output is an oracle: a caller could ask
///   "does any message contain `foo@`?" repeatedly and recover exactly the
///   identifiers the brief output withholds.
struct MailLogQuery: Equatable {
    let detail: MailLogDetail
    let start: Date
    let end: Date
    let categories: [LogCategoryToken]
    let contains: String?
    let redactIdentifiers: Bool
    let limit: Int
    /// Continuation only: how many matching events at exactly `start` (to the millisecond) were
    /// already returned by the previous page. See `MailLogService` for the cursor.
    var offset: Int = 0

    static let defaultMinutes = 10
    static let maxWindowSeconds: TimeInterval = 3600
    static let defaultLimit = 200

    /// The complete parameter list. The tool's input schema must list exactly
    /// these (pinned by `MailLogToolTests`), so the two cannot drift apart.
    static let allowedParameters: Set<String> = [
        "detail", "last_minutes", "since", "until", "around", "radius_seconds",
        "categories", "limit", "contains", "redact_identifiers", "offset",
    ]

    static func parse(_ arguments: [String: Value], now: Date) throws -> MailLogQuery {
        func invalid(_ message: String) -> MailError { MailError.invalidParameter(message) }

        let unknown = arguments.keys.filter { !allowedParameters.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw invalid("unknown parameter(s): \(unknown.joined(separator: ", ")) — allowed: \(allowedParameters.sorted().joined(separator: ", "))")
        }
        /// `null` counts as absent (clients send it for omitted optionals).
        func present(_ name: String) -> Value? {
            guard let v = arguments[name], v != .null else { return nil }
            return v
        }
        func integer(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
            guard let v = present(name) else { return nil }
            let n: Int
            switch v {
            case .int(let i): n = i
            case .double(let d) where d == d.rounded() && abs(d) < 1e15: n = Int(d)
            default: throw invalid("\(name) must be an integer")
            }
            guard range.contains(n) else {
                throw invalid("\(name) must be between \(range.lowerBound) and \(range.upperBound) (got \(n))")
            }
            return n
        }
        func timestamp(_ name: String) throws -> Date? {
            guard let v = present(name) else { return nil }
            guard case .string(let text) = v, let date = MailLogTime.parseISO8601WithOffset(text) else {
                throw invalid("\(name) must be an ISO 8601 timestamp with an explicit UTC offset "
                    + "(for example 2026-10-02T12:40:00+08:00, or Z for UTC) — a bare local time is refused "
                    + "because it would be read in whatever zone the reader assumes")
            }
            return date
        }

        // detail
        var detail = MailLogDetail.brief
        if let v = present("detail") {
            guard case .string(let text) = v, let parsed = MailLogDetail(rawValue: text) else {
                throw invalid("detail must be \"brief\" or \"detailed\"")
            }
            detail = parsed
        }

        // window — exactly one form
        let lastMinutes = try integer("last_minutes", in: 1...60)
        let since = try timestamp("since")
        let until = try timestamp("until")
        let around = try timestamp("around")
        let radius = try integer("radius_seconds", in: 1...1800)

        if until != nil, since == nil { throw invalid("until requires since") }
        if radius != nil, around == nil { throw invalid("radius_seconds requires around") }
        let formsUsed = [lastMinutes != nil, since != nil, around != nil].filter { $0 }.count
        guard formsUsed <= 1 else {
            throw invalid("choose exactly one window form: last_minutes, since (with optional until), or around (with optional radius_seconds)")
        }

        // Every bound is truncated to the millisecond here, once: the window the response states is
        // then exactly the window that is applied (verify round 2, finding 22).
        let floor = MailLogTime.floorToMillisecond
        let start: Date, end: Date
        if let around {
            let r = TimeInterval(radius ?? 60)
            start = floor(around.addingTimeInterval(-r))
            end = floor(around.addingTimeInterval(r))
        } else if let since {
            end = floor(until ?? now)
            // Closed interval: since == until is a one-millisecond window, and the continuation of a
            // page whose cursor reached window.end (verify round 2, finding 12).
            guard since <= end else { throw invalid("since must not be after until (or after now when until is omitted)") }
            start = floor(since)
        } else {
            end = floor(now)
            start = floor(now.addingTimeInterval(-TimeInterval((lastMinutes ?? defaultMinutes) * 60)))
        }
        guard end.timeIntervalSince(start) <= maxWindowSeconds else {
            throw invalid("the window must not be longer than 60 minutes")
        }

        // categories
        var categories: [LogCategoryToken] = []
        if let v = present("categories") {
            guard case .array(let items) = v else { throw invalid("categories must be an array of category names") }
            guard !items.isEmpty else { throw invalid("categories must not be empty when provided") }
            guard items.count <= 20 else { throw invalid("categories accepts at most 20 entries") }
            for item in items {
                guard case .string(let text) = item else { throw invalid("categories must contain only strings") }
                guard let token = LogCategoryToken(text) else {
                    throw invalid("invalid category \(text.debugDescription): a category may contain only letters, digits, '_', '.', '-' (1 to 64 characters)")
                }
                if !categories.contains(token) { categories.append(token) }
            }
        }

        // limit, and the continuation offset (meaningful only against a `since` cursor)
        let limit = try integer("limit", in: 1...1000) ?? defaultLimit
        let offset = try integer("offset", in: 0...1_000_000) ?? 0
        if present("offset") != nil, since == nil {
            throw invalid("offset requires since: it counts events already returned at exactly since (pass next_start and next_offset back together)")
        }

        // detailed-only parameters
        var contains: String?
        var redact = false
        if let v = present("contains") {
            guard detail == .detailed else {
                throw invalid("contains is only available with detail \"detailed\" — a substring filter on brief output would let a caller probe for the identifiers the brief output withholds")
            }
            guard case .string(let text) = v, (1...200).contains(text.count) else {
                throw invalid("contains must be a string of 1 to 200 characters")
            }
            contains = text
        }
        if let v = present("redact_identifiers") {
            guard detail == .detailed else {
                throw invalid("redact_identifiers is only available with detail \"detailed\"")
            }
            guard case .bool(let flag) = v else { throw invalid("redact_identifiers must be a boolean") }
            redact = flag
        }

        return MailLogQuery(detail: detail, start: start, end: end, categories: categories,
                            contains: contains, redactIdentifiers: redact, limit: limit, offset: offset)
    }
}
