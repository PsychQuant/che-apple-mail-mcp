# #700: what does Mail show after a reply is sent?

`reply_email` reported a send that never happened (#700). The fix on this branch
reports a send only after the reply's compose window has left Mail's window
list. Verification found that a window id may not be a reliable stand-in for
"this call's reply": the id is recorded before the send keystroke, and the list
of new windows is a before/after difference. This probe records what Mail
actually exposes, so the confirmation can be built on an observed signal.

## What the probe does

`probe.applescript` replies to one message, pastes a body, presses the send
keystroke, and then samples every 0.5 s for 20 s:

- whether the reply window's id is still in `id of every window`;
- whether the outgoing message the `reply` verb returned still exists;
- the number of outgoing messages;
- the number of sheets on the front window.

It closes nothing and retries nothing.

## Safety

The probe sends mail. Run it only against a test message whose sender and only
recipient is the maintainer (see the test-mail rule in `CLAUDE.md`).

- Send the test message to yourself first, and pass its reference.
- The third argument is the only address the reply may go to. After Mail builds
  the reply and before anything is typed, the script reads To, Cc and Bcc and
  stops unless there is at least one To address and every address equals that
  argument. On a stop, the reply window stays open and unsent.
- Delete the test message, the reply and any leftover draft afterwards.

## Run

```
osascript probe.applescript '<message reference>' '<body text>' '<your own address>'
```

The message reference is an AppleScript expression, for example
`(first message of mailbox "INBOX" of account id "<account id>" whose id is <n>)`.

Cases to record: Mail with no other window open; Mail with another viewer
window open; a reply that Mail holds back with a sheet.

## Results

Not run yet. Results go on the issue, with the macOS and Mail versions.
