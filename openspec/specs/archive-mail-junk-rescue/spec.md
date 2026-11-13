# archive-mail-junk-rescue Specification

## Purpose

Defines how `/archive-mail` reports archived mail that sits in an account's junk mailbox, when it asks the user about moving that mail back to the inbox, how it performs and confirms the move, how it remembers the decision for each sender, and in which situations it only lists the mail without touching the mailbox.

## Requirements

### Requirement: Report lists archived mail located in the junk mailbox

The archive-mail SOP SHALL classify every mail newly archived in the current run by comparing its `mailbox` with the junk mailbox of its own account, using the `get_special_mailboxes` result already fetched in Step 3 and keyed by the `account_id` the mail's search row carries. A mail SHALL count as located in the junk mailbox only when the account's `junk_path` is known and the mail's mailbox equals it by full path. A mail whose mailbox only shares the junk mailbox's last path segment or leaf name, including a mailbox equal to the `junk` leaf name when no `junk_path` is known, SHALL be listed separately as unconfirmed and SHALL NOT be offered for a move. The Step 7 report SHALL list both groups by file name, and SHALL omit the section when both groups are empty. The classification SHALL be computed before the report is printed; when it cannot be computed the report SHALL say so in one line and the rescue step SHALL NOT run. For every newly archived mail the SOP SHALL keep the `id`, `account_name`, `account_id`, `mailbox`, `sender`, `subject` and `date_received` of its search row together with the written file name, and SHALL NOT fill in an `account_id` the row does not carry. A mail that cannot be judged — no readable mailbox, no `account_id`, or an account whose special mailboxes were not read — SHALL NOT be dropped silently: it SHALL be counted, and the report SHALL show that count when it is above zero.

#### Scenario: mail in the account junk mailbox is listed

- **WHEN** a newly archived mail has a mailbox equal to its account's junk mailbox path
- **THEN** the Step 7 report lists its file under the junk mailbox section

##### Example: junk classification by mailbox path

| Mail mailbox | Account junk_path | Account junk leaf | Group |
| ------------ | ----------------- | ----------------- | ----- |
| `[Gmail]/垃圾郵件` | `[Gmail]/垃圾郵件` | `垃圾郵件` | in_junk |
| `Junk` | (none) | `Junk` | last_segment |
| `Clients/Junk` | (none) | `Junk` | last_segment |
| `Clients/垃圾郵件` | `[Gmail]/垃圾郵件` | `垃圾郵件` | last_segment |
| `垃圾郵件` | `[Gmail]/垃圾郵件` | `垃圾郵件` | last_segment |
| `INBOX` | `[Gmail]/垃圾郵件` | `垃圾郵件` | neither |
| `[Gmail]/垃圾郵件` | (special mailboxes of the account not read) | (not read) | counted as unreadable |
| (empty string) | `[Gmail]/垃圾郵件` | `垃圾郵件` | counted as unreadable |

---
### Requirement: Rescue question covers every undecided sender once

After Step 8.5 the SOP SHALL run a rescue step. When a person is present and at least one mail in the junk mailbox comes from a sender without a recorded decision, the SOP SHALL ask exactly one question that names every such sender and offers two answers: move all of them to the inbox, or leave all of them. The SOP SHALL NOT ask one question per mail or per sender. When every sender already has a recorded decision, the SOP SHALL NOT ask. When the question is asked, the SOP SHALL NOT call `mark_as_junk` or `move_email` for any mail — including mail from senders recorded as `rescue` — before the answer arrives; when no answer arrives it SHALL compute the plan again as a run with nobody present.

#### Scenario: one question for all undecided senders

- **WHEN** three archived mails sit in the junk mailbox and two of their senders have no recorded decision
- **THEN** the SOP asks one question naming those two senders

##### Example: senders to ask are deduplicated and sorted

- **GIVEN** mails in the junk mailbox from `b@example.invalid`, `a@example.invalid`, `b@example.invalid` and `c@example.invalid`, and a record with `c@example.invalid` decided as `leave`
- **WHEN** the rescue plan is computed for an attended run
- **THEN** the senders to ask are `a@example.invalid`, `b@example.invalid` in that order, and the mail from `c@example.invalid` is in the leave group

##### Example: no question when every sender is recorded

- **GIVEN** two mails in the junk mailbox, both from `a@example.invalid`, and a record with `a@example.invalid` decided as `rescue`
- **WHEN** the rescue plan is computed for an attended run
- **THEN** the senders to ask are empty and both mails are in the move group

---
### Requirement: Rescue moves the mail to the account inbox and reads it back

For each mail to rescue the SOP SHALL call `mark_as_junk` with `is_junk` false, then `move_email` from the mail's own mailbox to the same account's inbox (`inbox_path`, or `inbox` when no path is known), then read the result back with a fresh search. The arguments of all three calls SHALL be the ones the recipe produces for that mail. A failure of `mark_as_junk` SHALL be recorded in the report and SHALL NOT stop the move. A failure of `move_email` SHALL NOT stop the remaining mails, and the read-back SHALL still run for that mail: the reported outcome SHALL follow the read-back, with the tool error noted. The SOP SHALL report a mail as rescued only when the read-back finds no row that may be this mail in a junk mailbox, and finds a row that is this mail — equal subject, sender, received time and account — in a mailbox that is neither a junk mailbox nor the account's trash. A row may be this mail when its subject is equal and none of its sender, received time and account differs from the mail's; a field that cannot be read does not count as different. A row that may be this mail and has no readable mailbox SHALL make the outcome unconfirmed. Every other read-back result SHALL be reported as unconfirmed, including a failed or truncated search. The received time is the `date_received` of a `full` search row and the `date` of a `summary` row; the comparison SHALL compare instants and SHALL accept either name on both sides. The report SHALL state that a rescued outcome shows the mail left the junk mailbox and still exists in the account, not which mailbox Mail shows it in. A failure in the rescue step SHALL NOT make the archive run fail.

#### Scenario: read-back decides the reported outcome

- **WHEN** a mail was moved and the fresh search still returns a copy in the junk mailbox
- **THEN** the report lists the mail as unconfirmed

##### Example: read-back outcomes

The mail has subject `Statement`, sender `a@example.invalid`, received time `2026-10-16T06:32:19Z`, account `g`; the account's junk mailbox is `[Gmail]/垃圾郵件` and its trash is `[Gmail]/垃圾桶`. Unless a row says otherwise it carries the same subject, sender, time and account.

| Search rows | Outcome |
| ----------- | ------- |
| one row in `[Gmail]/全部郵件` | rescued |
| one row in `INBOX` and one in `[Gmail]/全部郵件` | rescued |
| one row in `[Gmail]/垃圾郵件` | unconfirmed |
| one row in `[Gmail]/垃圾郵件` and one in `INBOX` | unconfirmed |
| no rows | unconfirmed |
| one row in `INBOX` with a different received time | unconfirmed |
| one row in `[Gmail]/垃圾桶` | unconfirmed |
| one row in `INBOX`, and one row in `[Gmail]/垃圾郵件` whose sender cannot be read | unconfirmed |
| one row in `INBOX` that belongs to account `h` | unconfirmed |
| one row in `INBOX` with no `account_id` | unconfirmed |
| one row whose mailbox is an empty string | unconfirmed |
| one row in `INBOX` with the time written as `2026-10-16T06:32:19+00:00` | rescued |

#### Scenario: a failed junk flag change does not stop the move

- **WHEN** `mark_as_junk` returns an error for a mail to rescue
- **THEN** the SOP still calls `move_email` for that mail and the report records the flag failure

##### Example: rescue step text orders the three calls

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it names `mark_as_junk`, `move_email` and the read-back search in that order, states that a `mark_as_junk` failure is recorded and does not stop the move, states that the read-back still runs after a `move_email` error, and states that a rescue failure does not fail the archive run

---
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

---
### Requirement: A recorded sender is not asked again

When a sender has a valid recorded decision the SOP SHALL NOT ask about that sender. With a person present, mail from a sender recorded as `rescue` SHALL be moved without a question and listed in the report with the sender and the recorded time; mail from a sender recorded as `leave` SHALL only be listed. An entry whose decision is neither `rescue` nor `leave`, or that is not an object, SHALL be treated as absent, SHALL be reported as an invalid entry, and SHALL make the sender eligible for the question again.

#### Scenario: recorded decisions replace the question

- **WHEN** a mail in the junk mailbox comes from a sender recorded as `rescue` and a person is present
- **THEN** the SOP moves the mail without asking and the report lists it as moved by record

##### Example: plan by recorded decision

| Recorded entry for the sender | Attended plan for its mail |
| ----------------------------- | -------------------------- |
| `{"decision": "rescue", "decided_at": "2026-11-13T08:40:00+08:00"}` | move |
| `{"decision": "leave", "decided_at": "2026-11-13T08:40:00+08:00"}` | leave |
| `{"decision": "maybe"}` | ask, and the sender is reported as invalid |
| `"rescue"` | ask, and the sender is reported as invalid |
| (no entry) | ask |

---
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
### Requirement: An unattended run only lists

The SOP SHALL treat a run as having nobody present in exactly two situations: the run is marked unattended (a scheduled run, a headless run, or an orchestrator's unattended directive), or the rescue question received no answer. In both situations the SOP SHALL NOT ask, SHALL NOT move any mail — including mail from senders recorded as `rescue` — and SHALL NOT write the record. When the SOP cannot tell whether a person is present it SHALL act as if nobody is. The `--no-confirm` flag SHALL NOT grant the rescue step any permission.

#### Scenario: an unattended run leaves recorded senders alone

- **WHEN** an unattended run archives a mail from a sender recorded as `rescue`
- **THEN** the mail is listed with the reason that nobody is present and no mailbox-changing tool is called

##### Example: unattended plan

- **GIVEN** mails in the junk mailbox from `a@example.invalid` (recorded `rescue`), `b@example.invalid` (recorded `leave`) and `c@example.invalid` (no record)
- **WHEN** the rescue plan is computed with nobody present
- **THEN** the senders to ask and the move group are empty, the mail from `b@example.invalid` is in the leave group, and the mails from `a@example.invalid` and `c@example.invalid` are in the listed-only group with the reason `nobody-present`

##### Example: rescue step text excludes the no-confirm flag

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it lists exactly the two nobody-present situations, states that an unsure run acts as if nobody is present, and states that `--no-confirm` does not cover this step

---
### Requirement: Archive-mail pre-authorizes exactly the two mailbox-changing tools it needs

The archive-mail command SHALL pre-authorize `mark_as_junk` and `move_email` in addition to its nine read and export tools, and no other mailbox-changing tool. The command text SHALL state that these two tools are called only in the rescue step, only after the user's answer or a recorded `rescue` decision, and that `move_email` takes the account's junk mailbox as its source and the account's inbox as its only destination.

#### Scenario: the pre-authorized set is exact

- **WHEN** the command's `allowed-tools` are compared with the expected set
- **THEN** the mail tools are the nine read and export tools plus `mark_as_junk` and `move_email`, and nothing else

##### Example: archive-mail allowed mail tools

- **GIVEN** the frontmatter of the archive-mail command
- **WHEN** the mail tools in `allowed-tools` are collected
- **THEN** the set equals `search_emails`, `get_email`, `get_email_headers`, `list_accounts`, `get_special_mailboxes`, `list_attachments`, `list_attachments_batch`, `save_attachment`, `batch_export_emails_markdown`, `mark_as_junk`, `move_email`

##### Example: trust boundary text limits the two tools

- **GIVEN** the Trust boundary section of the archive-mail command
- **WHEN** its text is read
- **THEN** it no longer says the archive flow holds no move or junk permission, it counts eleven pre-authorized mail tools, and it states that `mark_as_junk` and `move_email` are used only in Step 9 with the inbox as the only destination

---
### Requirement: A stored sender decision is a consent source only for the rescue action

The confirmation rules SHALL list a fourth valid authorization source: a decision the user gave earlier in conversation and that the rescue step stored in the record file. The rule SHALL state that this source is valid only for moving that sender's mail from the junk mailbox to the inbox, that it cannot skip any other confirmation, that a record not written from the user's own answer (for example one brought in by a third-party clone) is not consent, and that an entry the user disowns is treated as absent.

#### Scenario: the rule names the fourth source and its limits

- **WHEN** the Provenance section of the confirmation rules is read
- **THEN** it lists four sources and the fourth is limited to the rescue action

##### Example: provenance lists the stored sender decision

- **GIVEN** the Provenance section of the confirmation-triggers rule
- **WHEN** its numbered list of valid sources is read
- **THEN** it has four items, the fourth names `junk_decisions.json`, limits it to moving mail from the junk mailbox to the inbox, and says a record from a third-party clone or a disowned entry is not consent

---
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

---
### Requirement: The rescue step computes its plan from the current record

The rescue step SHALL load the decision record and compute its plan again when it starts, and again after an answer has been recorded, and SHALL act only on the plan it computed last. It SHALL NOT act on the plan computed for the Step 7 report.

#### Scenario: a record that changed after the report is respected

- **WHEN** a sender's `rescue` entry is removed, or the record becomes unreadable, between the Step 7 report and the rescue step
- **THEN** the rescue step does not move that sender's mail on the earlier plan

##### Example: plan follows the record at the time it is computed

- **GIVEN** one mail in the junk mailbox from `a@example.invalid` and a record with `a@example.invalid` decided as `rescue`
- **WHEN** the plan is computed, then the record file is replaced by text that is not JSON, then the plan is computed again
- **THEN** the first plan has the mail in the move group and the second has it in the listed-only group with the reason `junk-decisions-not-json` and an empty move group

##### Example: rescue step text recomputes the plan

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it states that the step runs the plan again when it starts and again after recording an answer, and that the plan from the Step 7 report is not acted on

---
### Requirement: The decision record is used only in the form the rescue step writes

The recipe SHALL treat the record as unusable, and the run SHALL only list, when the record path is a symbolic link, when the file repeats a key, or when its `version` is not `1.0`. An entry SHALL count as a recorded decision only when it is an object whose `decision` is `rescue` or `leave` and whose `decided_at` is an ISO 8601 time with a UTC offset; any other entry SHALL be reported as invalid and its sender asked again. Two keys that name the same sender with different decisions SHALL make that sender invalid. A key that names no sender SHALL be counted and the count reported. The confirmation rules SHALL state that the command cannot verify who wrote the record.

#### Scenario: an entry without a decision time authorizes nothing

- **WHEN** the record holds `{"decision": "rescue"}` for a sender and nothing else
- **THEN** that sender's mail is asked about and the sender is reported as invalid

##### Example: record form errors

| Record file | senders | error |
| ----------- | ------- | ----- |
| `{"senders": {}}` | none | `junk-decisions-version-unsupported` |
| `{"version": "2.0", "senders": {}}` | none | `junk-decisions-version-unsupported` |
| `{"version": "1.0", "senders": {"a@example.invalid": {"decision": "leave", "decided_at": "2026-11-13T08:40:00+08:00"}, "a@example.invalid": {"decision": "rescue", "decided_at": "2026-11-13T08:40:00+08:00"}}}` | none | `junk-decisions-duplicate-key` |
| (the path is a symbolic link to a valid record) | none | `junk-decisions-unreadable` |

##### Example: entries that are not recorded decisions

| Entry for `a@example.invalid` | Attended plan for its mail |
| ----------------------------- | -------------------------- |
| `{"decision": "rescue"}` | ask, and the sender is reported as invalid |
| `{"decision": "rescue", "decided_at": "2026-11-13T08:40:00"}` | ask, and the sender is reported as invalid |
| `{"decision": "rescue", "decided_at": "yesterday"}` | ask, and the sender is reported as invalid |
| `{"decision": "rescue", "decided_at": "2026-11-13T08:40:00+08:00"}` | move |

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
### Requirement: Recorded moves are shown before they happen and the question says what is remembered

With a person present, the rescue step SHALL list the mails it is about to move on a recorded decision, with the sender and the recorded time, before the first call that changes the mailbox. The rescue question SHALL state that the answer is stored for each sender, that later mail from those senders is handled without asking, and where the record can be edited.

#### Scenario: recorded moves are visible first

- **WHEN** an attended run has mail to move on a recorded `rescue` decision
- **THEN** the list of those mails is printed before `mark_as_junk` or `move_email` is called

##### Example: rescue step text shows recorded moves first

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it requires the list of mails moved by record to be printed before any call that changes the mailbox, and requires the question to say that the answer is remembered per sender and where to delete it

---
### Requirement: Registered archive targets are outside the rescue step

The archive-mail command SHALL state that the junk mailbox lines of the report and the rescue step apply only to runs that are not handed to the registered-target flow, and that the registered-target flow SHALL NOT call `mark_as_junk` or `move_email`.

#### Scenario: the limitation is stated where the hand-off happens

- **WHEN** the trust boundary section of the archive-mail command is read
- **THEN** it names the registered-target flow as a place where the two tools are never called

##### Example: trust boundary text excludes the registered-target flow

- **GIVEN** the Trust boundary section and the Step 9 section of the archive-mail command
- **WHEN** their text is read
- **THEN** the Trust boundary states that the flow handed to archive-mail-tree does not call the two tools, and Step 9 states that registered targets are not covered

---
### Requirement: A flag or a workspace setting never authorizes the rescue move

The confirmation rules SHALL state that a command flag and a workspace setting, the second and third authorization sources, do not authorize moving mail out of the junk mailbox.

#### Scenario: the rule scopes the other sources out

- **WHEN** the Provenance section of the confirmation rules is read
- **THEN** it states that sources two and three do not authorize the rescue move

##### Example: provenance scopes flags and settings out of the rescue

- **GIVEN** the Provenance section of the confirmation-triggers rule
- **WHEN** its text is read
- **THEN** it states that neither a command flag nor a workspace setting authorizes moving mail from the junk mailbox to the inbox

---
### Requirement: The rescue step follows a reconcile gate that passed

The archive-mail command SHALL state that the reconcile gate is the last step of the archive itself and that only the rescue step follows it, and that the rescue step does not run when the gate did not pass, in which case its task is closed with that reason.

#### Scenario: a failed gate leaves the mailbox untouched

- **WHEN** the reconcile gate does not pass
- **THEN** the rescue step does not run and no mail is asked about or moved

##### Example: step order text

- **GIVEN** the Step 8.5 and Step 9 sections of the archive-mail command
- **WHEN** their text is read
- **THEN** Step 8.5 no longer says it is the last thing of the run without naming Step 9, and Step 9 states that it does not run when the Step 8.5 gate did not pass

---
### Requirement: A failed record write is reported by name and never raises

Recording an answer SHALL return an error name for every write failure and SHALL NOT raise, including when an existing key cannot be encoded as UTF-8. The record SHALL be written as ASCII JSON.

#### Scenario: an old key with an unpaired surrogate does not break recording

- **WHEN** the existing record has a key that contains an unpaired surrogate
- **THEN** recording a new answer returns without raising and the file stays valid JSON

##### Example: recording beside an unencodable key

- **GIVEN** a valid record whose `senders` object has the key `"\ud800"` with a `leave` entry
- **WHEN** the decisions `{"new@example.invalid": "rescue"}` are recorded at `2026-11-13T08:40:00+08:00`
- **THEN** the call returns no error, the file is ASCII, it loads again without error, and it holds both keys

---
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

---
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

---
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

---
### Requirement: The bulk move rule does not apply to the rescue step

The confirmation rules SHALL state that the bulk rule for `move_email` (five or more messages need a confirmation) does not apply to the rescue step, whose confirmation is its own question and the stored decision, and that the list shown before a move by record is a disclosure made in the same turn as the move, not a chance to stop it.

#### Scenario: the two rules no longer contradict each other

- **WHEN** the bulk section and the Provenance section of the confirmation rules are read
- **THEN** the bulk line names the rescue step as its exception and the Provenance section says so too

##### Example: bulk rule text names the rescue step

- **GIVEN** the confirmation-triggers rule and the Step 9 section of the archive-mail command
- **WHEN** their text is read
- **THEN** the bulk line for `move_email` names Step 9 as an exception, the Provenance section states that the bulk rule does not apply to Step 9 and that the list is only a disclosure, and Step 9 says the same without calling the list a chance to stop the move

---
### Requirement: An answer that could not be stored still applies to the run that asked

When recording the answer fails only at the write (`junk-decisions-write-failed`: the record could be read and could not be written), the rescue step SHALL still act on the answer the user gave in this conversation: it SHALL compute the plan again with that answer supplied as this run's answers, SHALL move the mail of the plan's move group, and SHALL report that the answer was not recorded and that the question will be asked again. This run's answers SHALL decide only the senders they name, SHALL be ignored unless every one of them is a bare lower-case address with `rescue` or `leave`, and SHALL be ignored when nobody is present or the record has a read error. When recording returns any other error, the rescue step SHALL move no mail in that run, including mail from senders already recorded as `rescue`, SHALL list every mail of the plan it started with as listed only with the error name, and SHALL NOT compute the plan again. When the plan computed after recording names a sender that was not in the question, the step SHALL NOT ask a second time and SHALL only list that sender's mail. The step SHALL tell the user to delete an entry or move the file away, not to edit entries. When the junk mailbox check of the report did not run, the step SHALL NOT run and its task SHALL be closed with that reason.

#### Scenario: a yes still moves the mail when the record cannot be written

- **WHEN** the user answers the question with "move" and writing the record fails
- **THEN** the mail of the senders in the question is moved in that run and the report says the answer was not recorded

#### Scenario: an answer that could not be stored changes no mailbox when the record is unreadable

- **WHEN** recording returns a read error of the record
- **THEN** no call that changes the mailbox is made in that run

##### Example: plan with answers that could not be stored

Mails in the junk mailbox from `a@example.invalid`, `b@example.invalid` and `c@example.invalid`; the record has `c@example.invalid` decided as `leave`.

| This run's answers | Attended | Record error | move | leave | ask |
| ------------------ | -------- | ------------ | ---- | ----- | --- |
| `a` rescue, `b` leave | yes | none | a | b, c | (none) |
| `a` with the decision `maybe` | yes | none | (none) | c | a, b |
| `a` rescue | no | none | (none) | c | (none; a and b are listed only, nobody present) |
| `a` rescue | yes | `junk-decisions-not-json` | (none) | (none) | (none; all listed only) |

##### Example: rescue step text on a failed recording

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it states that on a recording error other than a failed write nothing is moved in that run including the move group, that the plan is not computed again, that a sender appearing only in the plan computed after recording is not asked about a second time, that the user deletes an entry or moves the file away, and how the task is closed when the report's check did not run

##### Example: rescue step text on an unrecorded answer

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it states that when the write fails the user's consent in this conversation still holds, that the plan is computed again with the answers, and that the report says the answer was not recorded and will be asked again

---
### Requirement: A failed recipe call stops the rescue step

When a call of the recipe inside the rescue step cannot run, prints nothing or prints something that cannot be read, the step SHALL make no further call that changes the mailbox, SHALL report the mails already moved by the read-back results it has, and SHALL list the rest with the reason that the recipe failed. A recording that fails without an error name SHALL be treated as a recording error other than a failed write. When the plan computed after recording has any sender to ask, whether or not that sender was in the question, the step SHALL NOT ask again and SHALL only list that sender's mail. The answers passed to the plan after a failed write SHALL use the addresses of the plan's ask list unchanged. The report SHALL tell which moved mail was moved by an earlier record and which by this run's answer by the group its sender had in the plan the step started with, and SHALL NOT tell the user to delete an invalid entry in order to be asked again.

#### Scenario: a recipe that stops answering stops the moves

- **WHEN** the calls for a mail cannot be produced because the recipe fails to run
- **THEN** no further mail is marked or moved in that run

##### Example: rescue step text on a failed recipe call

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it names the four recipe calls, states that after a failed one no tool that changes the mailbox is called and the remaining mails are listed with the reason that the recipe failed, treats a recording that fails without an error name as an error other than a failed write, states that any sender left to ask after recording is not asked again, and states that the answers use the addresses of the ask list unchanged
