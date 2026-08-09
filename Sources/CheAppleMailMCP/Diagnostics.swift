import Foundation

/// The single sink for advisory diagnostics on stderr (#346).
///
/// ## Why this exists as its own type
///
/// The non-throwing `write` overload on `FileHandle.standardError` raises an
/// **uncatchable Objective-C exception** when the descriptor errors. Not a Swift
/// error: no `try?` and no `do/catch` can intercept it. The process aborts
/// (`SIGABRT`, exit 134), which #303 verified on the real binary.
///
/// #320 installed `signal(SIGPIPE, SIG_IGN)` so a write to a broken pipe stops
/// being a signal-13 kill. What that actually does is hand the write an `EPIPE`
/// errno — and the non-throwing API converts that into the abort above. So the
/// process-level fix alone changed *which number* the server died by, not
/// whether it died: a host closing its stderr read end could still be killed by
/// any of 26 advisory diagnostics.
///
/// The deeper reason for a separate type: #303 created a throwing writer, but
/// as a static on `MailController`. Nothing about that name says "process-wide
/// stderr sink", so 25 later sites had no reason to reach for it, and #320's
/// CHANGELOG could describe the server as safe ("the throwing stderr writes
/// swallow it") while 26 of 27 writers were not throwing. One obvious sink, in
/// a file named after the job, is what makes the invariant checkable —
/// `NoNonThrowingStderrWriteGuardTests` then enforces it.
///
/// ## Contract
///
/// Writes **verbatim**: no newline is added or removed. Every converted call
/// site already carries its own `\n`, and normalising here would either double
/// them or silently rewrite 26 messages. Callers that want the newline appended
/// use `MailController.emitDiagnostic`, which keeps #303's contract.
///
/// A diagnostic is advisory by definition, so a failed write is **swallowed** —
/// but reported, because #303's one-shot staleness gate must stay armed when
/// its only warning never reached anyone.
enum Diagnostics {

    /// Write `text` to stderr verbatim.
    ///
    /// - Returns: whether the bytes reached fd 2. `false` means the descriptor
    ///   was closed, broken, or read-only — never a reason to stop working.
    @discardableResult
    static func emit(_ text: String) -> Bool {
        do {
            try FileHandle.standardError.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }
}
