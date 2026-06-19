import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Functional probe of whether this process can actually read Apple Mail's
/// Envelope Index — the reliable signal for **Full Disk Access** status. macOS
/// exposes no query API for the FDA grant itself (#213), so the only honest
/// signal is "can we read the file?". We deliberately do NOT try to *name* the
/// responsible process to grant — there is no reliable in-process API for that
/// (#214: `responsibility_get_pid_responsible_for_pid` returns self). The probe
/// reports status only; the *guidance* (which app to grant) lives in
/// `FullDiskAccessHelp` and names candidates, it never guesses.
public enum FDAStatus {

    /// Result of the read probe.
    public enum Probe: Equatable {
        case granted       // the Envelope Index opened for reading — FDA is in effect
        case denied        // EPERM/EACCES — the open was refused (TCC) — FDA not granted
        case noMailData    // ENOENT — no Envelope Index on disk (Mail not set up) — can't tell
        case undetermined  // any other errno (EMFILE, EIO, EISDIR, …) — an unexpected error, not a clear denial
    }

    /// Probe FDA by attempting to open `path` for reading. `fopen` honors TCC.
    /// The `errno` after a failed open is discriminated precisely so we never
    /// report a transient/unexpected failure as a TCC denial (which would
    /// mislead the user into a pointless grant):
    ///   - `EPERM` / `EACCES` → `.denied` (the genuine FDA-refusal signal)
    ///   - `ENOENT`           → `.noMailData` (no file to read; Mail not set up)
    ///   - anything else      → `.undetermined` (EMFILE under fd exhaustion, EIO, …)
    ///
    /// Default path is the real Envelope Index; tests pass a temp path.
    public static func probe(path: String = EnvelopeIndexReader.defaultDatabasePath) -> Probe {
        #if canImport(Darwin)
        errno = 0
        if let fp = fopen(path, "rb") {
            fclose(fp)
            return .granted
        }
        // Capture errno immediately — any later call could clobber it.
        let err = errno
        switch err {
        case EPERM, EACCES: return .denied
        case ENOENT:        return .noMailData
        default:            return .undetermined
        }
        #else
        return .undetermined
        #endif
    }

    /// One-line human summary for CLI / `check_fda` tool output.
    public static func summary(_ probe: Probe) -> String {
        switch probe {
        case .granted:
            return "Full Disk Access: GRANTED — the Apple Mail Envelope Index is readable."
        case .denied:
            return "Full Disk Access: DENIED — the Envelope Index exists but this process can't read it (permission refused)."
        case .noMailData:
            // ENOENT is ambiguous: Mail may genuinely not be set up, OR Full Disk
            // Access is denied — ~/Library/Mail is a TCC-protected 0700 directory,
            // so a denial can surface as "no such file" (#213 verify, DA #8).
            return "Full Disk Access: UNKNOWN — no Apple Mail Envelope Index found (Mail isn't set up, OR Full Disk Access is denied and hiding it)."
        case .undetermined:
            return "Full Disk Access: UNDETERMINED — the Envelope Index couldn't be opened due to an unexpected error."
        }
    }
}
