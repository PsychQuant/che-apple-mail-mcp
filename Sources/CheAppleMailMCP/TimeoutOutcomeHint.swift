import Foundation

/// #522 — what a caller can do, without asking Mail again, after a Mail
/// operation timed out and its outcome is unknown.
///
/// These strings are guidance, not a verdict. The only evidence that can be
/// reported is a positive observation (a matching row); the absence of a row is
/// never reported as the absence of the operation. The Envelope Index is written
/// asynchronously, some accounts keep no Sent copy, and `search_emails` itself
/// can come back empty (#549, #536). There is no correlation marker on a message
/// the GUI flow creates, so a matching subject may be an earlier message, too.
///
/// The send-flow text avoids the phrase "nothing was sent": `ComposeRefusalTests`
/// forbids it anywhere in a post-dispatch message, because a bare "nothing was
/// sent" reads as a no-op claim even when it is negated.
///
/// The hint is a pure function of the kind: it never receives or echoes the
/// caller's subject (the generic "the subject you sent" is deliberate), so it
/// adds nothing the caller did not already hold.
///
/// Out of scope by design: the send gate (`unknownSendStateError`'s UNKNOWN and
/// NOT retrying, `isTimeoutError`, `isPostDispatchError`) is not touched by
/// anything in this file. See `.claude/rules/timeout-outcome-boundary.md`.
enum TimeoutOutcomeKind: CaseIterable {
    /// A GUI flow that may have sent the message (compose, reply, forward).
    case sendFlow
    /// A GUI flow that saves a draft (`create_draft`, `reply_email` with `save_as_draft`).
    case draftSave
    /// The scoped draft deletion inside `update_draft`.
    case draftDelete
}

func timeoutVerificationHint(_ kind: TimeoutOutcomeKind) -> String {
    switch kind {
    case .sendFlow:
        return "To look for evidence without asking Mail again, call search_emails with "
            + "field=\"subject\" and query set to the subject you sent, and read each result's "
            + "mailbox and date_received. A matching row is evidence that a message with that "
            + "subject exists in that mailbox; it may also be an earlier message with the same "
            + "subject. No matching row is NOT evidence that no message went out: the index is "
            + "written asynchronously, and some accounts keep no Sent copy. (search_emails reads "
            + "the Envelope Index and needs Full Disk Access; without it, it asks Mail through "
            + "AppleScript and may time out again.) Do not resend automatically in either case; "
            + "let the user decide."
    case .draftSave:
        return "If this call was saving a draft: call search_emails with field=\"subject\" and "
            + "query set to the draft's subject (reads the Envelope Index, needs Full Disk "
            + "Access), or list_drafts (asks Mail, so it can time out again). A matching row "
            + "means a draft with that subject exists, possibly an older one. No matching row "
            + "does not prove the draft was not saved; the index is written asynchronously. "
            + "Saving again may leave two drafts; delete the extra one."
    case .draftDelete:
        return "To observe the current state, call list_drafts (asks Mail, so it can time out "
            + "again) or search_emails with field=\"subject\" and query set to the draft's "
            + "subject (reads the Envelope Index, which can lag behind Mail). A row for the old "
            + "draft id that is still listed means the index still lists it; a missing row is "
            + "the index's view, not a confirmation from Mail. Do not retry the update or the "
            + "deletion until you have looked."
    }
}

/// #522 — the unknown-send-state message for `reply_email` / `forward_email`
/// (a post-dispatch GUI failure, or a send-flow timeout). It used to be built
/// inline at both call sites, with no test on either copy.
///
/// The wording before the hint is deliberately unchanged; #550 owns the
/// over-claim in it ("already dispatched" is also said for a timeout, where the
/// keystroke may not have fired). The hint sits before the clamped echo, because
/// `clampedErrorEcho` cuts the original error at 200 characters and a timeout
/// description is longer than that.
func unknownReplyForwardSendStateError(noun: String, error: Error) -> MailError {
    MailError.scriptFailed(
        message: "the send keystroke was already dispatched but a GUI step failed "
            + "afterwards — the send state is UNKNOWN and the \(noun) may already "
            + "be on the wire. Check Mail's Sent mailbox / Outbox and the original thread "
            + "before re-sending. The compose window (if still open) was left untouched "
            + "for inspection. "
            + timeoutVerificationHint(.sendFlow)
            + " Original error: "
            + clampedErrorEcho(error.localizedDescription),
        code: -1)
}
