import Foundation

/// #465 — one Mail unified-log event, as parsed from `log show --style ndjson`.
///
/// Carries the raw composed `message` because the *detailed* output needs it;
/// the *brief* output is built so it never reads `message` for anything but
/// integer extraction (see `TemplateExtractor`). Keeping both on one value type
/// makes that boundary the shaper's job, in one reviewable place.
struct MailLogEvent: Equatable {
    let time: Date
    let subsystem: String
    let category: String
    /// The static format template Apple's code logged with (`%@`, `%lu`, …) —
    /// no runtime data. This is the brief output's event name.
    let formatString: String
    /// The composed message. May contain account names, addresses, UUIDs.
    let message: String
    /// Base name of the emitting process image (e.g. `Mail`).
    let process: String
    let thread: Int
    let activity: Int
}
