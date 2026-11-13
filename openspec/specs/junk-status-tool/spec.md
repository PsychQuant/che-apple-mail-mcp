# junk-status-tool Specification

## Purpose

Defines what the `mark_as_junk` tool does to a message and what it reports back, so that a caller does not read "the flag was set" as "the message left the junk mailbox".

## Requirements

### Requirement: mark_as_junk reports the flag it read back and that it did not move the message

The `mark_as_junk` tool SHALL set the message's junk mail status, read the status back, and return a report that states the status as read back, states that the tool changes the flag only and did not move the message, names the mailbox the message was addressed in, and names `move_email` as the way to move it. When the status cannot be read back, the report SHALL say so and SHALL NOT state the status as a fact. The report SHALL NOT claim in which mailbox the message is after the call.

#### Scenario: a not-junk request on a message in the junk mailbox

- **WHEN** `mark_as_junk` is called with `is_junk` false for a message addressed in the junk mailbox and Mail reports the status as false afterwards
- **THEN** the result says the status is now false, that the tool did not move the message, and that `move_email` moves it

##### Example: report text by read-back

| is_junk | Read back | Mailbox | Report |
| ------- | --------- | ------- | ------ |
| false | false | `[Gmail]/垃圾郵件` | `Junk mail status is now false. mark_as_junk changes the flag only: it did not move the message, which was addressed in mailbox "[Gmail]/垃圾郵件". To move it, call move_email.` |
| true | true | `INBOX` | `Junk mail status is now true. mark_as_junk changes the flag only: it did not move the message, which was addressed in mailbox "INBOX". To move it, call move_email.` |
| false | unknown | `INBOX` | `Junk mail status was set to false, but it could not be read back. mark_as_junk changes the flag only: it did not move the message, which was addressed in mailbox "INBOX". To move it, call move_email.` |

---
### Requirement: mark_as_junk fails when the flag read back is the opposite of the request

When the status read back after the change is the opposite of the requested value, the tool SHALL return an error and SHALL NOT return a success report. The error SHALL state the requested value, the value read back, and that the message was not moved.

#### Scenario: Mail keeps the old status

- **WHEN** `mark_as_junk` is called with `is_junk` false and Mail still reports the status as true afterwards
- **THEN** the call fails with an error instead of reporting that the message was marked

##### Example: opposite read-back

- **GIVEN** a request with `is_junk` false for a message addressed in mailbox `INBOX`
- **WHEN** the status read back is true
- **THEN** the call fails with the message `Mail still reports junk mail status true after it was set to false. The message was addressed in mailbox "INBOX" and was not moved.`

---
### Requirement: The mark_as_junk script reads the flag back without failing the call

The script the tool runs SHALL set the junk mail status of the addressed message, then read that status back inside a `try` block, and SHALL return only `true`, `false`, or `unknown`. A read-back that fails SHALL yield `unknown` and SHALL NOT turn a change that succeeded into an error. Any script output other than `true` or `false` SHALL be read as unknown.

#### Scenario: a failed read-back does not fail the call

- **WHEN** the status is set and reading it back raises an error inside Mail
- **THEN** the script returns `unknown` and the tool returns the could-not-be-read-back report

##### Example: script shape and output parsing

- **GIVEN** the script built for message id `3` in mailbox `INBOX` with `is_junk` false
- **WHEN** its text is read, and the outputs `true`, ` false ` (with surrounding whitespace), `unknown`, an empty string and `maybe` are parsed
- **THEN** the script sets the junk mail status to false before a `try` block that reads the junk mail status of the same message, returns the value it read, and no longer contains the text `Email marked as`; the outputs parse as true, false, unknown, unknown and unknown

##### Example: tool result through a fake script runner

| is_junk | Script output | Result |
| ------- | ------------- | ------ |
| false | `false` | the report that begins `Junk mail status is now false.` |
| false | `unknown` | the report that begins `Junk mail status was set to false, but it could not be read back.` |
| false | `true` | an error that begins `Mail still reports junk mail status true` |

---
### Requirement: The mark_as_junk description says it changes the flag only

The description of the `mark_as_junk` tool SHALL state that it changes the junk flag only, that it does not move the message, and that `move_email` moves a message.

#### Scenario: a caller reading the tool list

- **WHEN** the tool list is read
- **THEN** the `mark_as_junk` entry tells the caller that the message stays where it is

##### Example: description text

- **GIVEN** the tool list of the server
- **WHEN** the description of `mark_as_junk` is read
- **THEN** it contains `flag only`, `does not move` and `move_email`
