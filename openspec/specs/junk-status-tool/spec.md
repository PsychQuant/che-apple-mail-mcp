# junk-status-tool Specification

## Purpose

Defines what the `mark_as_junk` tool does to a message and what it reports back, so that a caller does not read "the flag was set" as "the message left the junk mailbox".

## Requirements

### Requirement: mark_as_junk reports the flag it read back and that it did not move the message

The `mark_as_junk` tool SHALL set the message's junk mail status, read the status back from the same message in the mailbox the caller addressed, and return a report. When the status read back equals the requested value, the report SHALL state the status as the value Mail reports, that the tool changes the flag only and issued no move, that Mail still found the message in the addressed mailbox when the flag was read back, and `move_email` as the way to move it. When the status cannot be read back, the report SHALL say so, SHALL NOT state the status as a fact, SHALL NOT state in which mailbox the message is, and SHALL tell the caller to search for the message again before calling `move_email`. The report SHALL NOT state that the message stays in a mailbox after the call: a successful read-back is evidence for the moment of the read only.

#### Scenario: a not-junk request on a message in the junk mailbox

- **WHEN** `mark_as_junk` is called with `is_junk` false for a message addressed in the junk mailbox and Mail reports the status as false afterwards
- **THEN** the result says Mail reports the status as false, that the tool issued no move, that Mail still found the message in that mailbox when the flag was read back, and that `move_email` moves it

#### Scenario: the flag cannot be read back

- **WHEN** the status is set and the read-back yields no value
- **THEN** the result says the status could not be read back, does not name a mailbox the message is in, and tells the caller to search for the message again before moving it

##### Example: report text by read-back

| is_junk | Read back | Mailbox | Report |
| ------- | --------- | ------- | ------ |
| false | false | `[Gmail]/垃圾郵件` | `Mail reports junk mail status false after the change. mark_as_junk changes the flag only: it issued no move, and Mail still found the message in mailbox "[Gmail]/垃圾郵件" when the flag was read back. To move it, call move_email.` |
| true | true | `INBOX` | `Mail reports junk mail status true after the change. mark_as_junk changes the flag only: it issued no move, and Mail still found the message in mailbox "INBOX" when the flag was read back. To move it, call move_email.` |
| false | unknown | `INBOX` | `Junk mail status was set to false, but it could not be read back from mailbox "INBOX". mark_as_junk changes the flag only and issued no move. If Mail moved the message on its own, the message has a new id: search for it again before calling move_email.` |

---
### Requirement: mark_as_junk fails when the flag read back is the opposite of the request

When the status read back after the change is the opposite of the requested value, the tool SHALL return an error and SHALL NOT return a success report. The error SHALL state the requested value, the value read back, that the tool issued no move, and that Mail still found the message in the addressed mailbox when the flag was read back. A request for the value the message already has, read back as that value, is a success and not an error.

#### Scenario: Mail keeps the old status

- **WHEN** `mark_as_junk` is called with `is_junk` false and Mail still reports the status as true afterwards
- **THEN** the call fails with an error instead of reporting that the message was marked

##### Example: opposite read-back

- **GIVEN** a request with `is_junk` false for a message addressed in mailbox `INBOX`
- **WHEN** the status read back is true
- **THEN** the call fails with the message `Mail still reports junk mail status true after it was set to false. mark_as_junk issued no move, and Mail still found the message in mailbox "INBOX" when the flag was read back.`

---
### Requirement: The mark_as_junk script reads the flag back without failing the call

The script the tool runs SHALL resolve the addressed message once into a variable, set the junk mail status through that variable, then read that status back through the same variable inside a `try` block, and SHALL return only `true`, `false`, or `unknown`: `true` when the status read is true, `false` when it is false. The message reference SHALL appear in the script exactly once, so that the read-back does not search for the message again. A read-back that raises an error inside Mail SHALL yield `unknown` and SHALL NOT turn a change that succeeded into an error. Any script output other than `true` or `false` SHALL be read as unknown. This requirement covers errors that Mail raises: a script that exceeds the time limit of the script runner still fails as a timeout, even when the status was already changed.

#### Scenario: a failed read-back does not fail the call

- **WHEN** the status is set and reading it back raises an error inside Mail
- **THEN** the script returns `unknown` and the tool returns the could-not-be-read-back report

##### Example: script shape and output parsing

- **GIVEN** the script built for message id `3` in mailbox `INBOX` of the account with a given id, once with `is_junk` false and once with `is_junk` true
- **WHEN** its text is read, and the outputs `true`, ` false ` (with surrounding whitespace), `unknown`, an empty string and `maybe` are parsed
- **THEN** the whole script equals: a `tell application "Mail"` block that sets `msg` to the reference of message `3` in `INBOX` of that account, sets `junk mail status of msg` to the requested value, sets `flagNow` to `"unknown"`, then inside a `try` block sets `flagNow` to `"true"` if `junk mail status of msg` and to `"false"` otherwise, and returns `flagNow`; the message reference appears exactly once; the text `Email marked as` does not appear; the outputs parse as true, false, unknown, unknown and unknown

##### Example: tool result through a fake script runner

| is_junk | Script output | Result |
| ------- | ------------- | ------ |
| false | `false` | the report that begins `Mail reports junk mail status false after the change.` |
| false | `unknown` | the report that begins `Junk mail status was set to false, but it could not be read back` |
| false | `true` | an error that begins `Mail still reports junk mail status true` |

---
### Requirement: The mark_as_junk description says it changes the flag only

The description of the `mark_as_junk` tool SHALL state that it changes the junk flag only, that the tool issues no move, and that `move_email` moves a message. The description SHALL NOT state that the message stays in the mailbox it is in: the tool does not establish what Mail does with the message.

#### Scenario: a caller reading the tool list

- **WHEN** the tool list is read
- **THEN** the `mark_as_junk` entry tells the caller that the tool itself moves nothing and that a success does not mean the message left the junk mailbox

##### Example: description text

- **GIVEN** the tool list of the server
- **WHEN** the description of `mark_as_junk` is read
- **THEN** it contains `flag only`, `issues no move` and `move_email`, and it does not contain `stays there`
