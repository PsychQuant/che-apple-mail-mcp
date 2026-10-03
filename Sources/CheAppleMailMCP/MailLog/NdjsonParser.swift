import Foundation

/// #465 — one line of `log show --style ndjson`.
enum NdjsonLine: Equatable {
    case event(MailLogEvent)
    /// The `{"count":N,"finished":1}` trailer `log show` ends with. Not an event, not an error.
    case trailer
    /// Valid JSON object that is neither an event nor the trailer. If Apple renames the
    /// timestamp key, EVERY line lands here — so these are counted, never silently dropped.
    case unrecognized
    /// Not JSON, not an object, or an event whose timestamp cannot be read.
    /// The caller counts these in `skipped_lines`.
    case malformed
}

enum NdjsonParser {
    static func parse(_ line: Data) -> NdjsonLine {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .malformed
        }
        guard let stamp = object["timestamp"] else {
            // The ONLY timestamp-less object `log show` writes is its closing {"count":N,"finished":1}.
            return Set(object.keys) == ["count", "finished"] ? .trailer : .unrecognized
        }
        guard let text = stamp as? String, let time = MailLogTime.parseLogTimestamp(text) else {
            return .malformed
        }
        func string(_ key: String) -> String { (object[key] as? String) ?? "" }
        func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        return .event(MailLogEvent(
            time: time,
            subsystem: string("subsystem"),
            category: string("category"),
            formatString: string("formatString"),
            message: string("eventMessage"),
            // Base name only: the full image path is local-machine detail the
            // tool has no reason to hand to a caller.
            process: (string("processImagePath") as NSString).lastPathComponent,
            thread: int("threadID"),
            activity: int("activityIdentifier")))
    }
}
