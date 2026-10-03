import Foundation

/// #465 — time handling for the log tool.
///
/// Two rules drive all of it:
///
/// 1. **Every time that crosses the tool boundary carries an explicit UTC offset.** The maintainer
///    works in UTC+8; a bare "2026-10-02 12:40:00" is silently read as whatever zone the reader
///    assumes, which is how a window ends up eight hours off with no error.
/// 2. **The resolution is the millisecond, and sub-millisecond digits are TRUNCATED, never rounded.**
///    The log carries microseconds, `ISO8601DateFormatter` ROUNDS when it prints fractional seconds
///    (`…26.4786 → .479`), and a paging cursor that rounds up can land after events it never
///    returned. Verify round 1 flagged this; the pipeline happened to be safe only because
///    `DateFormatter` truncates when it parses — an undocumented side effect. Both directions are
///    explicit here and pinned by tests.
struct MailLogTime {
    private let formatter: ISO8601DateFormatter

    /// Formats in `timeZone` (production passes `.autoupdatingCurrent` so a long-running server
    /// follows a change of zone; tests pass a fixed zone so expected strings are literals).
    init(timeZone: TimeZone) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        formatter = f
    }

    /// ISO 8601 with offset and millisecond precision, floored: `2026-10-02T12:42:26.431+08:00`.
    func format(_ date: Date) -> String {
        let (whole, ms) = Self.split(date)
        let base = formatter.string(from: Date(timeIntervalSince1970: whole))
        let zoneLength = base.hasSuffix("Z") ? 1 : 6                     // "Z" or "+08:00"
        let cut = base.index(base.endIndex, offsetBy: -zoneLength)
        return String(base[..<cut]) + String(format: ".%03d", ms) + String(base[cut...])
    }

    /// Whole seconds and the floored millisecond. A `Date` holds about 0.24 µs of resolution at
    /// current epochs, so a value like 26.802 is stored as 26.80199…; the 0.5 µs tolerance absorbs
    /// that and nothing larger — `.802999` stays 802 (verify round 2, finding 16: a 1 µs tolerance
    /// carried genuine remainders of 999 µs up to the next millisecond).
    private static func split(_ date: Date) -> (whole: Double, ms: Int) {
        let t = date.timeIntervalSince1970
        let whole = t.rounded(.down)
        return (whole, max(0, min(999, Int((((t - whole) * 1000) + 0.0005).rounded(.down)))))
    }

    /// The same instant truncated to the millisecond — the only resolution the tool speaks.
    static func floorToMillisecond(_ date: Date) -> Date {
        let (whole, ms) = split(date)
        return Date(timeIntervalSince1970: whole).addingTimeInterval(Double(ms) / 1000)
    }

    /// Integer milliseconds since 1970, for "same millisecond" comparisons that must not depend on
    /// how two equal instants were computed.
    static func millisecondKey(_ date: Date) -> Int64 {
        let (whole, ms) = split(date)
        return Int64(whole) * 1000 + Int64(ms)
    }

    // MARK: - Parsing

    private static let isoShape = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$"#)
    private static let logShape = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:\.(\d+))?([+-]\d{4})$"#)

    private static let wholeSecondsISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let wholeSecondsLog: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ssZ"; return f
    }()

    private static func groups(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// First three fractional digits, as milliseconds (".5" → 500, ".802999" → 802).
    private static func milliseconds(fromFraction digits: String?) -> Double {
        guard let digits, !digits.isEmpty else { return 0 }
        return Double(Int(String((digits + "000").prefix(3))) ?? 0) / 1000
    }

    /// Parses ISO 8601 that carries an explicit offset (or `Z`). Anything without one — a bare date,
    /// a bare local time — is `nil`, so the caller can refuse it by name instead of guessing a zone.
    /// A date the calendar does not contain (`2026-02-30`, `24:00:00`) is `nil` too, not normalized.
    static func parseISO8601WithOffset(_ text: String) -> Date? {
        guard let g = groups(isoShape, text), let local = g[0], let zone = g[2],
              let base = wholeSecondsISO.date(from: local + zone) else { return nil }
        // Normalization check: formatting back in the SAME offset must reproduce the digits we were given.
        let seconds = zone == "Z" ? 0 : (zone.hasPrefix("-") ? -1 : 1)
            * ((Int(zone.dropFirst(1).prefix(2)) ?? 0) * 3600 + (Int(zone.suffix(2)) ?? 0) * 60)
        let echo = ISO8601DateFormatter()
        echo.formatOptions = [.withInternetDateTime]
        echo.timeZone = TimeZone(secondsFromGMT: seconds)
        guard echo.string(from: base).hasPrefix(local) else { return nil }
        return base.addingTimeInterval(milliseconds(fromFraction: g[1]))
    }

    /// The shape `log show --style ndjson` uses: `2026-10-02 15:36:39.802432+0800`.
    static func parseLogTimestamp(_ text: String) -> Date? {
        guard let g = groups(logShape, text), let local = g[0], let zone = g[2],
              let base = wholeSecondsLog.date(from: local + zone) else { return nil }
        return base.addingTimeInterval(milliseconds(fromFraction: g[1]))
    }
}
