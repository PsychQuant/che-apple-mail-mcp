import Foundation

/// Best-effort "download the attachment first" machinery for `save_attachment`
/// (#272, Option B).
///
/// ## Why this is best-effort, not a real download command
///
/// The Phase-0 feasibility spike (#272) confirmed from Mail's scripting
/// dictionary that **there is no `download` verb** for a `mail attachment`:
/// the class only `responds-to save`, and `downloaded` is a read-only
/// property. The ONLY lever AppleScript exposes is to make Mail *materialize*
/// the full message — which, on an IMAP account, pulls the server-side body
/// (and its attachments) into the local store as a side effect. Reading
/// `source of theMessage` (the raw RFC 822) is the least-intrusive such nudge:
/// unlike `open theMessage` it opens no viewer window, yet it still forces Mail
/// to have the complete message.
///
/// Whether that side effect *actually* pulls a not-downloaded attachment is
/// **unverified** (the spike found no not-downloaded attachment on this machine
/// to live-test against, and #238(a) already flagged `save`'s fetch-triggering
/// as unproven). So this path is opt-in (`download_if_missing`, default off),
/// bounded by a timeout, and fails **honestly**: if materialization does not
/// bring the attachment down within the deadline, the caller still gets the
/// existing `not_downloaded` error — never a false "saved".
///
/// Free functions + a value type (not methods on `MailController`) so the
/// script text, the gate, and the poll schedule are unit-testable without
/// spinning up the actor — same pattern as `SaveAttachmentScriptBuilder`.

// MARK: - Fetch-trigger script

/// Build the AppleScript that nudges Mail to fetch a server-side-only
/// attachment by materializing its message.
///
/// Resolves the message through the shared `resolveMsgRef` chokepoint (UUID
/// selector when `accountId` is non-empty, else the legacy display_name form —
/// byte-identical to `save_attachment`'s own resolution) and reads its `source`
/// to force a full-message fetch. The result is discarded; only the fetch side
/// effect matters. Wrapped in `try` so a transient resolution error on the
/// nudge is non-fatal — the subsequent save-retry is the real success test.
///
/// - Parameters:
///   - id: Message ROWID (numeric; a non-numeric value is neutralized to the
///     impossible id `-1` by `resolveMsgRef`, release-safe guard #118).
///   - mailbox: Mailbox name (nested on-disk paths handled by resolveMsgRef).
///   - accountId: Optional account UUID; non-nil AND non-empty → UUID selector.
///   - accountName: Display name; used only in the fallback path.
/// - Returns: a complete AppleScript program (never scans bodies — #221).
func buildTriggerDownloadScript(
    id: String,
    mailbox: String,
    accountId: String?,
    accountName: String
) -> String {
    let msgRef = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
    return """
    tell application "Mail"
        set theMessage to \(msgRef)
        try
            set _forceFetch to source of theMessage
        end try
    end tell
    """
}

// MARK: - Gating predicate

/// Decide whether `save_attachment` should enter the best-effort download-retry
/// path instead of failing immediately.
///
/// Returns `true` ONLY when all three hold, so the default behavior is
/// preserved for every caller who does not opt in:
/// - `notDownloaded`: local `.emlx` state PROVED the part is server-side only
///   (Tier-1 threw `attachmentNotDownloaded`, #238), and
/// - `scriptCode == -10000`: the Tier-2 AppleScript save failed with the
///   generic unfetched-binary AppleEvent error (a specific code like -1728
///   "bad account" is a real error, not a missing download), and
/// - `downloadIfMissing`: the caller explicitly asked for the retry.
func shouldAttemptDownloadRetry(
    notDownloaded: Bool,
    scriptCode: Int,
    downloadIfMissing: Bool
) -> Bool {
    return notDownloaded && scriptCode == -10000 && downloadIfMissing
}

/// #347 — the second entry into the same retry loop: the save *claimed* success
/// but the write did not verify.
///
/// Note what is **not** required here. The `-10000` path above needs the
/// separate `notDownloaded` proof because a generic AppleScript error says
/// nothing about where the bytes are. A 0-byte (or absent) file after a
/// reported success **is** that evidence — there is nothing further to
/// corroborate, so opt-in alone qualifies.
///
/// `.notRegular` is excluded deliberately: polling cannot turn a directory or
/// a FIFO into a regular file, so retrying it would only spend the caller's
/// 30-second budget before failing with the same message.
func shouldAttemptDownloadRetry(
    afterUnverifiedWrite problem: AttachmentWriteProblem,
    downloadIfMissing: Bool
) -> Bool {
    guard downloadIfMissing else { return false }
    switch problem {
    case .empty, .missing: return true
    case .notRegular:      return false
    }
}

// MARK: - Retry policy

/// Bounds for the best-effort download-retry loop: how long to keep polling and
/// how long to wait between save attempts. A pure value so the schedule is
/// testable without real timers.
struct DownloadRetryPolicy {
    /// Total wall-clock budget for the retry loop (seconds).
    let timeout: TimeInterval
    /// Delay between successive save attempts (seconds).
    let pollInterval: TimeInterval

    /// Default: give Mail up to 30s to fetch, re-checking every 2s. A single
    /// opt-in call, single message — bounded and interruptible.
    static let `default` = DownloadRetryPolicy(timeout: 30, pollInterval: 2)

    /// Upper bound on save attempts, derived from the budget. Never below 1
    /// (a zero would make the loop a silent no-op) and never a divide-by-zero
    /// on a degenerate zero/negative interval.
    var maxAttempts: Int {
        guard pollInterval > 0 else { return 1 }
        return max(1, Int(timeout / pollInterval))
    }
}
