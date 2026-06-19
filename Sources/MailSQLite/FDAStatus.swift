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
        case granted      // the Envelope Index opened for reading — FDA is in effect
        case denied       // the file exists but the open was refused (TCC) — FDA not granted
        case noMailData   // no Envelope Index on disk (Apple Mail never set up) — can't tell
    }

    /// Probe FDA by attempting to open `path` for reading. `fopen` honors TCC, so
    /// a refused open (`EPERM`/`EACCES`) means FDA is not granted, while `ENOENT`
    /// means there is simply no Mail data to read.
    ///
    /// Default path is the real Envelope Index; tests pass a temp path.
    public static func probe(path: String = EnvelopeIndexReader.defaultDatabasePath) -> Probe {
        #if canImport(Darwin)
        errno = 0
        if let fp = fopen(path, "rb") {
            fclose(fp)
            return .granted
        }
        // Distinguish "no such file" from "refused".
        return errno == ENOENT ? .noMailData : .denied
        #else
        return .denied
        #endif
    }

    /// One-line human summary for CLI / `check_fda` tool output.
    public static func summary(_ probe: Probe) -> String {
        switch probe {
        case .granted:
            return "Full Disk Access: GRANTED — the Apple Mail Envelope Index is readable."
        case .denied:
            return "Full Disk Access: DENIED — the Envelope Index exists but this process can't read it."
        case .noMailData:
            return "Full Disk Access: UNKNOWN — no Apple Mail Envelope Index on disk yet (Mail not set up)."
        }
    }
}
