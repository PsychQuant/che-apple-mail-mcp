## MODIFIED Requirements

### Requirement: The sender address is the bracket group that ends the sender field

The recipe SHALL read the address of a mail's sender field from the bracket group that ends the field, which is where the server writes it. A mail's sender field that does not end with a bracket group SHALL be treated as unreadable, because the server writes that form only when the message has no address and the text is a display name. A record key and an answer are bare addresses and SHALL be read from the whole string. A field whose display name contains a bracket, or contains an address different from the one in the final group, SHALL be treated as unreadable. An address that is not ASCII SHALL be treated as unreadable before any case folding, and so SHALL an address whose domain has no dot or ends with a dot. A mail whose sender is unreadable SHALL only be listed.

#### Scenario: a display name cannot stand in for the address

- **WHEN** a mail's sender field carries a recorded address in its display name and a different address in its final bracket group
- **THEN** the mail is neither moved by that record nor asked about under that address

##### Example: ambiguous sender fields

| Sender field | Record key |
| ------------ | ---------- |
| `x <notice@bank.invalid> <attacker@evil.invalid>` | (empty: unreadable) |
| `"<notice@bank.invalid>" <attacker@evil.invalid>` | (empty: unreadable) |
| `notice@bank.invalid <attacker@evil.invalid>` | (empty: unreadable) |
| `Notice <x> <notice@bank.invalid>` | (empty: unreadable) |
| `notice@bank.invalid <Notice@Bank.invalid>` | `notice@bank.invalid` |
| `Bank <attacker@evil.invalid>` | `attacker@evil.invalid` |
| `notice@banK.invalid` (the `K` is U+212A) | (empty: unreadable) |
| `<notice@bank.invalid> trailing` | (empty: unreadable) |

##### Example: mail sender fields without a bracket group

| A mail's sender field | Address read for the mail |
| --------------------- | ------------------------- |
| `Bank <a@example.invalid>` | `a@example.invalid` |
| ` <a@example.invalid>` | `a@example.invalid` |
| `a@example.invalid` | (empty: unreadable) |
| `Bank Notice` | (empty: unreadable) |

A mail whose sender field is `a@example.invalid`, with `a@example.invalid` recorded as `rescue`, is listed with the reason `sender-unreadable` and is not moved. As a record key, `a@b` and `a@b.invalid.` are not addresses.

## ADDED Requirements

### Requirement: Rescue calls are produced only for mail in the junk mailbox with a readable sender

The recipe SHALL produce the arguments of the three calls for a mail only when the mail's account has a known `junk_path`, the mail's mailbox equals it by full path, and the mail's sender is readable, whatever list the caller took the mail from. For every other mail it SHALL produce none.

#### Scenario: a mail outside the junk mailbox gets no move arguments

- **WHEN** the calls are requested for a mail whose mailbox is the inbox
- **THEN** the recipe returns none

##### Example: rescue calls refused

| Mail | Account | Calls |
| ---- | ------- | ----- |
| mailbox `INBOX` | junk_path `[Gmail]/垃圾郵件` | none |
| mailbox `[Gmail]/全部郵件` | junk_path `[Gmail]/垃圾郵件` | none |
| mailbox `Clients/Junk` | no junk_path, leaf `Junk` | none |
| mailbox `Junk` | no junk_path, leaf `Junk` | none |
| mailbox `[Gmail]/垃圾郵件`, sender `Bank Notice` | junk_path `[Gmail]/垃圾郵件` | none |
| mailbox `[Gmail]/垃圾郵件`, sender field `a@example.invalid` (no bracket group) | junk_path `[Gmail]/垃圾郵件` | none |
| mailbox `[Gmail]/垃圾郵件`, sender `Sender <a@example.invalid>` | junk_path `[Gmail]/垃圾郵件` | the three calls |

### Requirement: A record that is not strict JSON or is reached through a link is unusable

The recipe SHALL treat the record as unusable, and the run SHALL only list, when the file contains a constant that is not JSON (`NaN`, `Infinity`, `-Infinity`), when the file or the directory that holds it is a symbolic link, when it is not a regular file, or when it is larger than four mebibytes. An entry SHALL count as a recorded decision only when its key is the sender's bare lower-case address and its `decided_at` has the form `YYYY-MM-DDThh:mm:ss`, an optional fraction, then `Z` or an offset `+hh:mm`; an entry under any other spelling of the key, or with any other time form, SHALL make that sender invalid. The command SHALL state that directories above the one that holds the record are not checked.

#### Scenario: a record with a non-JSON constant only lists

- **WHEN** an entry of the record carries `NaN` in any field
- **THEN** the loader reports `junk-decisions-not-json` and no mail is asked about or moved

##### Example: strict record errors

| Record | error |
| ------ | ----- |
| a valid record whose entry has `"extra": NaN` | `junk-decisions-not-json` |
| the same with `Infinity` | `junk-decisions-not-json` |
| the same with `-Infinity` | `junk-decisions-not-json` |
| the same with `"extra": 1` | none |
| a valid record in a directory reached through a symbolic link | `junk-decisions-unreadable` |
| a record larger than four mebibytes | `junk-decisions-unreadable` |

Recording through the linked directory returns `junk-decisions-unreadable` and leaves the file behind the link unchanged.

### Requirement: Recording and planning never raise on a record that loaded

Recording an answer SHALL return `junk-decisions-write-failed`, and SHALL NOT raise, when an entry kept from the existing record cannot be encoded again. The plan the recipe writes out SHALL NOT contain the record itself: it SHALL carry only the recorded time of each sender whose mail is in the move or leave group.

#### Scenario: a deeply nested old entry does not end in a traceback

- **WHEN** the existing record holds a value nested thousands of levels deep and an answer is recorded
- **THEN** the call returns an error name and the old file is unchanged

##### Example: recording beside a deeply nested entry

- **GIVEN** a record whose `senders` object has the key `x@example.invalid` with a value of 3000 nested arrays
- **WHEN** the decisions `{"a@example.invalid": "rescue"}` are recorded, and then the plan is computed from the command line for one mail in the junk mailbox
- **THEN** recording returns `junk-decisions-write-failed` or `junk-decisions-not-json` without raising, the file is unchanged, no temporary file is left, and the plan command exits with status 0 and writes valid JSON

##### Example: plan output carries recorded times, not the record

- **GIVEN** one mail in the junk mailbox from `a@example.invalid` and a record with `a@example.invalid` decided as `rescue` at `2026-11-13T08:40:00+08:00`
- **WHEN** the plan is computed from the command line
- **THEN** the output has the mail in the move group, `decided_at` equal to `{"a@example.invalid": "2026-11-13T08:40:00+08:00"}`, and no `senders` key

### Requirement: A failed recording moves nothing

When recording the answer returns an error, the rescue step SHALL move no mail in that run, including mail from senders already recorded as `rescue`, SHALL list every mail of the plan it started with as listed only with the error name, and SHALL NOT compute the plan again. When the plan computed after recording names a sender that was not in the question, the step SHALL NOT ask a second time and SHALL only list that sender's mail. The step SHALL tell the user to delete an entry or move the file away, not to edit entries. When the junk mailbox check of the report did not run, the step SHALL NOT run and its task SHALL be closed with that reason.

#### Scenario: an answer that could not be stored changes no mailbox

- **WHEN** the user answers the question and the record cannot be written
- **THEN** no call that changes the mailbox is made in that run

##### Example: rescue step text on a failed recording

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it states that on a recording error nothing is moved in that run including the move group, that the plan is not computed again, that a sender appearing only in the plan computed after recording is not asked about a second time, that the user deletes an entry or moves the file away, and how the task is closed when the report's check did not run

### Requirement: The bulk move rule does not apply to the rescue step

The confirmation rules SHALL state that the bulk rule for `move_email` (five or more messages need a confirmation) does not apply to the rescue step, whose confirmation is its own question and the stored decision, and that the list shown before a move by record is a disclosure made in the same turn as the move, not a chance to stop it.

#### Scenario: the two rules no longer contradict each other

- **WHEN** the bulk section and the Provenance section of the confirmation rules are read
- **THEN** the bulk line names the rescue step as its exception and the Provenance section says so too

##### Example: bulk rule text names the rescue step

- **GIVEN** the confirmation-triggers rule and the Step 9 section of the archive-mail command
- **WHEN** their text is read
- **THEN** the bulk line for `move_email` names Step 9 as an exception, the Provenance section states that the bulk rule does not apply to Step 9 and that the list is only a disclosure, and Step 9 says the same without calling the list a chance to stop the move
