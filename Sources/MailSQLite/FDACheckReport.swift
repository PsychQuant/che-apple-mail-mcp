import Foundation

/// The text `check_fda` returns, as a pure function of two facts (#537):
///
/// - `probe`: what the `fopen` read probe saw (the old, only input), and
/// - `index`: what the server's own index reader did when `check_fda` asked it
///   to retry (`IndexReaderProvider.forceRetry()`).
///
/// They can disagree. Before #537 the report trusted the probe alone, so a
/// server whose reader had failed to open at startup still answered "the SQLite
/// fast path should now work". The probe says whether the file can be read; only
/// the reader's own open says whether this server can use it.
///
/// The existing wording for the three non-granted probe results is kept; what
/// changes is the granted branch, and every branch now also states the reader's
/// state when it contradicts the probe.
public enum FDACheckReport {

    public static func text(probe: FDAStatus.Probe, index: IndexReaderProvider.RetryOutcome) -> String {
        switch probe {
        case .granted:
            return granted(index)
        case .denied:
            return "⚠️ " + FDAStatus.summary(probe) + "\n\n"
                + FullDiskAccessHelp.guidance(reason: "Full Disk Access is required for the SQLite fast path.")
                + readerNote(index)
        case .noMailData:
            // ENOENT is ambiguous (no Mail vs FDA-denied hiding the dir) — present
            // BOTH possibilities so an FDA-denied user isn't told the opposite of the fix.
            return "ℹ️ " + FDAStatus.summary(probe)
                + "\nIf Apple Mail IS configured, this most likely means Full Disk Access is denied"
                + " (a denial can hide ~/Library/Mail). Grant it:\n\n"
                + FullDiskAccessHelp.guidance(reason: "If Full Disk Access is the cause:")
                + "\n\nIf Mail genuinely isn't set up, add an account first, then re-check."
                + readerNote(index)
        case .undetermined:
            // An unexpected errno, not a clear TCC denial — offer the FDA steps conditionally.
            return "⚠️ " + FDAStatus.summary(probe)
                + "\nThis is not a clear permission denial; retry first. If it persists and Full Disk"
                + " Access might be the cause:\n\n"
                + FullDiskAccessHelp.guidance(reason: "If Full Disk Access is the cause:")
                + readerNote(index)
        }
    }

    // MARK: - granted

    private static func granted(_ index: IndexReaderProvider.RetryOutcome) -> String {
        let summary = FDAStatus.summary(.granted)
        switch index {
        case .alreadyAvailable:
            return "✅ " + summary
                + "\nThis server's index reader is open, so the SQLite fast path"
                + " (search_emails projection, batch_export_emails_markdown) is available."
        case .recovered(let prior):
            let earlier = prior.map { " (\(IndexReaderProvider.firstLine($0)))" } ?? ""
            return "✅ " + summary
                + "\nThis server's index reader could not be opened earlier\(earlier) and has just"
                + " recovered: the SQLite fast path is available again."
                + truncatedCaveat
        case .stillUnavailable(let failure):
            return "⚠️ " + summary
                + "\nThe probe can read the file, but this server's own attempt to open the index"
                + " failed: \(IndexReaderProvider.firstLine(failure))"
                + "\nUntil it opens, read tools run on the AppleScript fallback and the SQLite-only"
                + " features (search_emails projection=ids/count/summary, batch_export_emails_markdown)"
                + " fail. Reconnect the server (/mcp in Claude Code, or restart Claude Desktop) so it"
                + " starts with a fresh process. If it fails the same way after reconnecting, the probe"
                + " and the SQLite open disagree; please include this output when reporting it."
        }
    }

    /// Recovery moves reads from the AppleScript path to the SQLite path, and the
    /// two decide `truncated` differently (SQLite fetches limit+1 and is exact;
    /// AppleScript estimates), so say so before someone compares before and after.
    private static let truncatedCaveat =
        "\nReads made before now ran on the AppleScript fallback. The two paths decide `truncated`"
        + " differently (SQLite is exact, AppleScript estimates), so a repeated search may report it"
        + " differently."

    // MARK: - probe says "not granted"

    /// Appended when the reader's state contradicts a probe that was not
    /// granted: an open reader means the fast path works regardless of the probe.
    private static func readerNote(_ index: IndexReaderProvider.RetryOutcome) -> String {
        switch index {
        case .alreadyAvailable:
            return "\n\nNote: this server's index reader is open, so the SQLite fast path is available"
                + " even though the probe above did not read the file (the probe and the SQLite open disagree)."
        case .recovered(let prior):
            let earlier = prior.map { " (\(IndexReaderProvider.firstLine($0)))" } ?? ""
            return "\n\nNote: this server's index reader is open now, so the SQLite fast path is available"
                + " even though the probe above did not read the file (the probe and the SQLite open disagree)."
                + " It could not be opened earlier\(earlier) and has just recovered."
                + truncatedCaveat
        case .stillUnavailable(let failure):
            return "\n\nThis server's own attempt to open the index failed: \(IndexReaderProvider.firstLine(failure))"
        }
    }
}
