## MODIFIED Requirements

### Requirement: A reply or forward is reported as sent only after its compose window has closed

When `reply_email`, or `forward_email` with a body, sends (that is, `save_as_draft` is `false` or omitted), the GUI script SHALL record, in the same Mail block that checks the frontmost Mail window is one this call opened and before the send keystroke is dispatched, the id of that frontmost window: the window the keystroke goes to. After dispatching the keystroke the script SHALL check in Mail's own context whether that window id is still present, and SHALL repeat the check every 0.5 seconds until it is absent or the confirmation wait has elapsed. Other windows that appeared during the call SHALL NOT be watched. The confirmation wait SHALL default to 10 seconds and SHALL be configurable through `CHE_MAIL_SEND_CONFIRM_WAIT` to a value from 0 to 10 seconds; a value outside that range or not a number SHALL give the default; the wait SHALL be rounded up to a multiple of 0.5 seconds and at least one check SHALL always run, so a value of 0 still waits 0.5 seconds. The script SHALL return its success label only when a check found the window absent. When the wait elapses with the window still present, the script SHALL raise an error that carries the post-dispatch sentinel followed by `SENDUNCONFIRMED:`, and SHALL NOT close that window. The system SHALL report that error as an unknown send state: the message SHALL say that the compose window was still open, that the send state is UNKNOWN, and that the call is NOT retrying, SHALL direct the caller to look at that compose window and any sheet on it, SHALL say that a window that is still open does not show that nothing went out, SHALL NOT instruct the caller to send the message, and SHALL carry the send-flow verification hint before the echo of the original error; the error it returns SHALL be neither a timeout nor a post-dispatch error. An error raised by a check itself SHALL be reported with the existing post-dispatch message. The messages for a send-flow timeout and for every other post-dispatch failure SHALL be unchanged. The draft flow (`save_as_draft: true`) SHALL NOT run this check, and neither does a forward without a body, which runs another script (#731). The success label states that the keystroke was dispatched and the compose window closed; the check cannot tell that apart from a window closed by hand during the wait. The tool descriptions of `reply_email` and `forward_email` SHALL say what the success means, SHALL say that it is not a confirmation that the mail server accepted the message, and SHALL say that a window closed by hand looks the same; the description of `forward_email` SHALL limit the statement to a forward with a body and SHALL say that a forward without a body has no such check. Until the check has been run against a live send and that run is recorded on #700, both descriptions SHALL also say that it has not been; that sentence is temporary and is removed with the run.

#### Scenario: The compose window closes after the send keystroke

- **WHEN** a sending reply's script dispatches the send keystroke and a later check does not find the window it went to
- **THEN** the script returns `Reply sent successfully (paste path)`

#### Scenario: The compose window is still open when the wait ends

- **WHEN** every check within the confirmation wait still finds the window the keystroke went to
- **THEN** the script raises `POSTDISPATCH: SENDUNCONFIRMED: …` without closing the window, and the tool reports an unknown send state that points at the open compose window, does not retry and does not tell the caller to send

#### Scenario: Another window that opened during the call stays open

- **WHEN** a window other than the one the keystroke went to appeared during the call and is still open after the send
- **THEN** it does not affect the result, because only the window the keystroke went to is watched

#### Scenario: A draft is not subject to the check

- **WHEN** `reply_email` is called with `save_as_draft: true`
- **THEN** the script contains no confirmation check and closes its own window after saving, as before

##### Example: send confirmation by window close

| Tool | save_as_draft | Script after the dispatch keystroke | Result when the window is gone | Result when the window stays |
| --- | --- | --- | --- | --- |
| `reply_email` | omitted | polls `id of every window` for the id of the window the keystroke went to | `Reply sent successfully (paste path)` | `POSTDISPATCH: SENDUNCONFIRMED:` error, window left open |
| `forward_email` with a body | omitted | polls `id of every window` for the id of the window the keystroke went to | `Email forwarded successfully (paste path)` | `POSTDISPATCH: SENDUNCONFIRMED:` error, window left open |
| `reply_email` | `true` | no poll; closes its own window | `Reply saved as draft (paste path)` | not applicable |
| `forward_email` with a body | `true` | no poll; closes its own window | `Forward saved as draft (paste path)` | not applicable |

##### Example: send confirmation wait

| `CHE_MAIL_SEND_CONFIRM_WAIT` | Checks, 0.5 s apart | Seconds named in the unconfirmed error |
| --- | --- | --- |
| unset | 20 | 10.0 |
| `2` | 4 | 2.0 |
| `0.6` | 2 | 1.0 |
| `0` | 1 | 0.5 |
| `10` | 20 | 10.0 |
| `99` | 20 | 10.0 |
| `-1` | 20 | 10.0 |
| `soon` | 20 | 10.0 |

##### Example: unconfirmed send message

| Input error | Message says | Message does not say | Returned error |
| --- | --- | --- | --- |
| `POSTDISPATCH: SENDUNCONFIRMED: …` | compose window still open; send state UNKNOWN; NOT retrying; look at the compose window and any sheet; an open window does not show that nothing went out; send-flow hint before `Original error:` | an instruction to send; `already on the wire` as a fact; `safe to retry` | `scriptFailed`, code -1, not a timeout, not post-dispatch |
| `POSTDISPATCH: window gone` | the existing post-dispatch wording, unchanged | — | unchanged |
| a script timeout | the existing timeout wording, unchanged | — | unchanged |
