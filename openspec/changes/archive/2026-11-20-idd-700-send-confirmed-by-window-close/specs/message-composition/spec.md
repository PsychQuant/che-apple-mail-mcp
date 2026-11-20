## ADDED Requirements

### Requirement: A reply or forward is reported as sent only after its compose window has closed

When `reply_email`, or `forward_email` with a body, sends (that is, `save_as_draft` is `false` or omitted), the GUI script SHALL, after dispatching the send keystroke, check in Mail's own context whether any window this call opened (identified by the window ids that appeared when the native reply or forward verb ran) is still present, and SHALL repeat that check at a fixed interval until no such window remains or the confirmation wait has elapsed. The confirmation wait SHALL default to 10 seconds and SHALL be configurable through `CHE_MAIL_SEND_CONFIRM_WAIT` to a value from 0 to 10 seconds; at least one check SHALL always run. The script SHALL return its success label only when a check found none of those windows. When the wait elapses with such a window still present, the script SHALL raise an error that carries the post-dispatch sentinel followed by `SENDUNCONFIRMED:`, and SHALL NOT close that window. The system SHALL report that error as an unknown send state: the message SHALL say that the compose window was still open, that the send state is UNKNOWN, and that the call is NOT retrying, SHALL direct the caller to that compose window, and SHALL carry the send-flow verification hint before the echo of the original error; the error it returns SHALL be neither a timeout nor a post-dispatch error. The messages for a send-flow timeout and for every other post-dispatch failure SHALL be unchanged. The draft flow (`save_as_draft: true`) SHALL NOT run this check. The success label states that the keystroke was dispatched and the compose window closed; the tool descriptions of `reply_email` and `forward_email` SHALL say so, SHALL say that this is not a confirmation that the mail server accepted the message, and SHALL say that the check has not yet been run against a live send (tracked in #700).

#### Scenario: The compose window closes after the send keystroke

- **WHEN** a sending reply's script dispatches the send keystroke and a later check finds none of the windows it opened
- **THEN** the script returns `Reply sent successfully (paste path)`

#### Scenario: The compose window is still open when the wait ends

- **WHEN** every check within the confirmation wait still finds a window this call opened
- **THEN** the script raises `POSTDISPATCH: SENDUNCONFIRMED: …` without closing the window, and the tool reports an unknown send state that names the open compose window and does not retry

#### Scenario: A draft is not subject to the check

- **WHEN** `reply_email` is called with `save_as_draft: true`
- **THEN** the script contains no confirmation check and closes its own window after saving, as before

##### Example: send confirmation by window close

| Tool | save_as_draft | Script after the dispatch keystroke | Result when the window is gone | Result when the window stays |
| --- | --- | --- | --- | --- |
| `reply_email` | omitted | polls `id of every window` against the ids it opened | `Reply sent successfully (paste path)` | `POSTDISPATCH: SENDUNCONFIRMED:` error, window left open |
| `forward_email` with a body | omitted | polls `id of every window` against the ids it opened | `Email forwarded successfully (paste path)` | `POSTDISPATCH: SENDUNCONFIRMED:` error, window left open |
| `reply_email` | `true` | no poll; closes its own window | `Reply saved as draft (paste path)` | not applicable |
| `forward_email` with a body | `true` | no poll; closes its own window | `Forward saved as draft (paste path)` | not applicable |

##### Example: unconfirmed send message

| Input error | Message says | Message does not say | Returned error |
| --- | --- | --- | --- |
| `POSTDISPATCH: SENDUNCONFIRMED: …` | compose window still open; send state UNKNOWN; NOT retrying; look at the compose window; send-flow hint before `Original error:` | `already on the wire` as a fact; `safe to retry` | `scriptFailed`, code -1, not a timeout, not post-dispatch |
| `POSTDISPATCH: window gone` | the existing post-dispatch wording, unchanged | — | unchanged |
| a script timeout | the existing timeout wording, unchanged | — | unchanged |
