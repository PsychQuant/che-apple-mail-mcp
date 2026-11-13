## MODIFIED Requirements

### Requirement: Sender decisions are recorded in a dedicated per-target file

The SOP SHALL store the user's answer in `junk_decisions.json` inside the archive target's state directory, separate from `email_index.json` and `threads.json`. The file SHALL hold a `version` and a `senders` object keyed by the sender's bare address in lower case, each value holding `decision` (`rescue` or `leave`) and `decided_at` (an ISO 8601 time with a UTC offset). The SOP SHALL write the file only from an answer the user gave in the conversation, SHALL keep every existing sender entry it did not change, and SHALL replace the file atomically. A mail whose sender cannot be reduced to an address SHALL NOT be recorded and SHALL only be listed. An address SHALL be accepted only when its local part uses letters, digits and `. _ % + -` and its domain uses letters, digits, `.` and `-`; any other address SHALL be treated as unreadable, because the address is shown in a question and stored as a key. A write that fails SHALL return the error name `junk-decisions-write-failed`, SHALL leave the existing file unchanged and SHALL leave no temporary file; a write whose result would be larger than four mebibytes, the size above which the record is no longer read, SHALL count as a failed write. Whether mail is still moved on an answer that could not be written is stated by the requirement 'An answer that could not be stored still applies to the run that asked'.

#### Scenario: an answer is recorded per sender

- **WHEN** the user answers the rescue question with "move" for two senders
- **THEN** the record holds one `rescue` entry for each of the two senders with the time of the answer

##### Example: sender normalization

| Sender field | Record key |
| ------------ | ---------- |
| `"Bank Notice" <NOTICE@Example.invalid>` | `notice@example.invalid` |
| `notice@example.invalid` | `notice@example.invalid` |
| `  <Notice@Example.Invalid>  ` | `notice@example.invalid` |
| `Bank Notice` | (empty: not recorded) |
| (not a string) | (empty: not recorded) |
| ``a`b@example.invalid`` | (empty: not recorded) |
| `$(x)@example.invalid` | (empty: not recorded) |
| `a b@example.invalid` | (empty: not recorded) |
| `a@b@example.invalid` | (empty: not recorded) |

##### Example: recording keeps earlier entries

- **GIVEN** a record with `old@example.invalid` decided as `leave` at `2026-11-01T09:00:00+08:00`
- **WHEN** the decisions `{"new@example.invalid": "rescue"}` are recorded at `2026-11-13T08:40:00+08:00`
- **THEN** the file holds both senders, `old@example.invalid` keeps its decision and time, `new@example.invalid` has `rescue` and `2026-11-13T08:40:00+08:00`, and no temporary file is left in the directory

---

##### Example: a write that would exceed the size limit

- **GIVEN** a record of about 2.4 mebibytes that loads without error, whose one entry carries an extra field of 800000 non-ASCII characters
- **WHEN** the decisions `{"a@example.invalid": "rescue"}` are recorded
- **THEN** the call returns `junk-decisions-write-failed`, the file is unchanged and still loads, and no temporary file is left

### Requirement: A corrupt decision record leaves the mailbox untouched

When `junk_decisions.json` exists and cannot be read (for example the path is a directory or the file is not readable), or is not valid JSON, or its top level is not an object, or it has no `senders` object (the key is missing or its value is not an object), the SOP SHALL NOT ask, SHALL NOT move any mail and SHALL NOT write the file in that run. The report SHALL carry one line `junk_decisions_error` with the error name and SHALL list the mails in the junk mailbox. A missing file SHALL be treated as an empty record and SHALL NOT be an error.

#### Scenario: a corrupt record stops the rescue step

- **WHEN** the record file contains text that is not JSON
- **THEN** the rescue step lists the mails, reports the error name, and makes no tool call that changes the mailbox

##### Example: record loader results

| File content | senders | error |
| ------------ | ------- | ----- |
| (file missing) | `{}` | none |
| `{"version": "1.0", "senders": {}}` | `{}` | none |
| `{"version": "1.0"}` | none | `junk-decisions-senders-not-object` |
| `not json` | none | `junk-decisions-not-json` |
| (empty file) | none | `junk-decisions-not-json` |
| `[]` | none | `junk-decisions-not-object` |
| `{"senders": []}` | none | `junk-decisions-senders-not-object` |
| `{"senders": null}` | none | `junk-decisions-senders-not-object` |
| (the path is a directory) | none | `junk-decisions-unreadable` |

##### Example: an error plans no question and no move and refuses to write

- **GIVEN** two mails in the junk mailbox and the loader error `junk-decisions-not-json`
- **WHEN** the rescue plan is computed for an attended run and a write of `{"a@example.invalid": "rescue"}` is attempted
- **THEN** the senders to ask and the move group are empty, both mails are in the listed-only group with the reason `junk-decisions-not-json`, the write returns that error name, and the file content is unchanged

---

### Requirement: Nothing is changed for a mail whose rescue cannot be completed and checked

Before any call that changes the mailbox, the plan SHALL only list a mail that has no `id` or `account_name`, whose account has no known inbox, whose account names no junk mailbox or no trash mailbox (the read-back could then never confirm the move), or for which no read-back search can be built (no subject, or a received time that is not an ISO 8601 time with an offset or lies at the edge of the representable range), each with its own reason. The recipe SHALL produce the arguments of the three calls for a mail, and SHALL produce none for a mail that is only listed.

#### Scenario: a mail without a known inbox is not unjunked

- **WHEN** a mail's account has neither `inbox_path` nor `inbox`
- **THEN** the mail is listed with the reason `inbox-unknown` and `mark_as_junk` is not called for it

##### Example: mails that are only listed before any call

| What the mail or its account lacks | Reason |
| ---------------------------------- | ------ |
| `id` | `mail-unaddressable` |
| the account's inbox | `inbox-unknown` |
| a received time with an offset (`date_received` is `Friday, 16 October 2026`) | `readback-unavailable` |
| a subject | `readback-unavailable` |
| the account's trash mailbox name | `readback-unavailable` |

##### Example: rescue calls for one mail

- **GIVEN** a mail with id `101`, account name `Example`, account id `g`, mailbox `[Gmail]/垃圾郵件`, subject `Statement`, received time `2026-10-16T06:32:19Z`, in an account whose `inbox_path` is `INBOX`
- **WHEN** the calls are produced
- **THEN** `mark_as_junk` gets id `101`, account name `Example`, account id `g`, mailbox `[Gmail]/垃圾郵件` and `is_junk` false; `move_email` gets the same id and account with `from_mailbox` `[Gmail]/垃圾郵件` and `to_mailbox` `INBOX`; the search gets query `Statement`, field `subject`, account name `Example`, `date_from` `2026-10-16T06:31:19Z`, `date_to` `2026-10-16T06:33:19Z`, projection `full` and limit 200

---

## ADDED Requirements

### Requirement: A failed recipe call stops the rescue step

When a call of the recipe inside the rescue step cannot run, prints nothing or prints something that cannot be read, the step SHALL make no further call that changes the mailbox, SHALL report the mails already moved by the read-back results it has, and SHALL list the rest with the reason that the recipe failed. A recording that fails without an error name SHALL be treated as a recording error other than a failed write. When the plan computed after recording has any sender to ask, whether or not that sender was in the question, the step SHALL NOT ask again and SHALL only list that sender's mail. The answers passed to the plan after a failed write SHALL use the addresses of the plan's ask list unchanged. The report SHALL tell which moved mail was moved by an earlier record and which by this run's answer by the group its sender had in the plan the step started with, and SHALL NOT tell the user to delete an invalid entry in order to be asked again.

#### Scenario: a recipe that stops answering stops the moves

- **WHEN** the calls for a mail cannot be produced because the recipe fails to run
- **THEN** no further mail is marked or moved in that run

##### Example: rescue step text on a failed recipe call

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it names the four recipe calls, states that after a failed one no tool that changes the mailbox is called and the remaining mails are listed with the reason that the recipe failed, treats a recording that fails without an error name as an error other than a failed write, states that any sender left to ask after recording is not asked again, and states that the answers use the addresses of the ask list unchanged
