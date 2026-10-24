import Foundation

/// #522 — the unknown-send-state message for `reply_email` / `forward_email`
/// (a post-dispatch GUI failure, or a send-flow timeout). It used to be built
/// inline at both call sites, with no test on either copy.
///
/// The wording is deliberately unchanged here; #550 owns the over-claim in it
/// ("already dispatched" is also said for a timeout, where the keystroke may not
/// have fired).
func unknownReplyForwardSendStateError(noun: String, error: Error) -> MailError {
    MailError.scriptFailed(
        message: "the send keystroke was already dispatched but a GUI step failed "
            + "afterwards — the send state is UNKNOWN and the \(noun) may already "
            + "be on the wire. Check Mail's Sent mailbox / Outbox and the original thread "
            + "before re-sending. The compose window (if still open) was left untouched "
            + "for inspection. Original error: "
            + clampedErrorEcho(error.localizedDescription),
        code: -1)
}
