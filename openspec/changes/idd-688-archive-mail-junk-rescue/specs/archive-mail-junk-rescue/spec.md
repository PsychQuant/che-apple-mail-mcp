## Purpose

Defines how `/archive-mail` reports archived mail that sits in an account's junk mailbox, when it asks the user about moving that mail back to the inbox, how it performs and confirms the move, how it remembers the decision for each sender, and in which situations it only lists the mail without touching the mailbox.

## ADDED Requirements

### Requirement: Report lists archived mail located in the junk mailbox

The archive-mail SOP SHALL classify every mail newly archived in the current run by comparing its `mailbox` with the junk mailbox of its own account, using the `get_special_mailboxes` result already fetched in Step 3. A mail SHALL count as located in the junk mailbox only when its mailbox equals that account's `junk_path` by full path, or equals the `junk` leaf name by full path when no `junk_path` is known. A mail whose mailbox matches the junk name only by its last path segment SHALL be listed separately as unconfirmed and SHALL NOT be offered for a move. The Step 7 report SHALL list both groups by file name, and SHALL omit the section when both groups are empty.

#### Scenario: mail in the account junk mailbox is listed

- **WHEN** a newly archived mail has a mailbox equal to its account's junk mailbox path
- **THEN** the Step 7 report lists its file under the junk mailbox section

##### Example: junk classification by mailbox path

| Mail mailbox | Account junk_path | Account junk leaf | Group |
| ------------ | ----------------- | ----------------- | ----- |
| `[Gmail]/垃圾郵件` | `[Gmail]/垃圾郵件` | `垃圾郵件` | in_junk |
| `Junk` | (none) | `Junk` | in_junk |
| `Clients/Junk` | (none) | `Junk` | last_segment |
| `Clients/垃圾郵件` | `[Gmail]/垃圾郵件` | `垃圾郵件` | last_segment |
| `INBOX` | `[Gmail]/垃圾郵件` | `垃圾郵件` | neither |
| `[Gmail]/垃圾郵件` | (account unknown) | (account unknown) | neither |

### Requirement: Rescue question covers every undecided sender once

After Step 8.5 the SOP SHALL run a rescue step. When a person is present and at least one mail in the junk mailbox comes from a sender without a recorded decision, the SOP SHALL ask exactly one question that names every such sender and offers two answers: move all of them to the inbox, or leave all of them. The SOP SHALL NOT ask one question per mail or per sender. When every sender already has a recorded decision, the SOP SHALL NOT ask.

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

### Requirement: Rescue moves the mail to the account inbox and reads it back

For each mail to rescue the SOP SHALL call `mark_as_junk` with `is_junk` false, then `move_email` from the account's junk mailbox to the account's inbox (`inbox_path`, or `inbox` when no path is known), then read the result back with a fresh subject search. A failure of `mark_as_junk` SHALL be recorded in the report and SHALL NOT stop the move. A failure of `move_email` SHALL mark that mail as failed and SHALL NOT stop the remaining mails. The SOP SHALL report a mail as rescued only when the read-back finds no copy of it (same subject, sender and received time) in the junk mailbox and finds a copy in another mailbox; every other read-back result SHALL be reported as unconfirmed. A failure in the rescue step SHALL NOT make the archive run fail.

#### Scenario: read-back decides the reported outcome

- **WHEN** a mail was moved and the fresh search still returns a copy in the junk mailbox
- **THEN** the report lists the mail as unconfirmed

##### Example: read-back outcomes

| Search results for the same subject, sender and received time | Outcome |
| ------------------------------------------------------------- | ------- |
| one row in `[Gmail]/全部郵件` | rescued |
| one row in `INBOX` and one in `[Gmail]/全部郵件` | rescued |
| one row in `[Gmail]/垃圾郵件` | unconfirmed |
| one row in `[Gmail]/垃圾郵件` and one in `INBOX` | unconfirmed |
| no rows | unconfirmed |
| one row in `INBOX` with a different received time | unconfirmed |

#### Scenario: a failed junk flag change does not stop the move

- **WHEN** `mark_as_junk` returns an error for a mail to rescue
- **THEN** the SOP still calls `move_email` for that mail and the report records the flag failure

##### Example: rescue step text orders the three calls

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it names `mark_as_junk`, `move_email` and the read-back search in that order, states that a `mark_as_junk` failure is recorded and does not stop the move, and states that a rescue failure does not fail the archive run

### Requirement: Sender decisions are recorded in a dedicated per-target file

The SOP SHALL store the user's answer in `junk_decisions.json` inside the archive target's state directory, separate from `email_index.json` and `threads.json`. The file SHALL hold a `version` and a `senders` object keyed by the sender's bare address in lower case, each value holding `decision` (`rescue` or `leave`) and `decided_at` (an ISO 8601 time with a UTC offset). The SOP SHALL write the file only from an answer the user gave in the conversation, SHALL keep every existing sender entry it did not change, and SHALL replace the file atomically. A mail whose sender cannot be reduced to an address SHALL NOT be recorded and SHALL only be listed.

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

##### Example: recording keeps earlier entries

- **GIVEN** a record with `old@example.invalid` decided as `leave` at `2026-11-01T09:00:00+08:00`
- **WHEN** the decisions `{"new@example.invalid": "rescue"}` are recorded at `2026-11-13T08:40:00+08:00`
- **THEN** the file holds both senders, `old@example.invalid` keeps its decision and time, `new@example.invalid` has `rescue` and `2026-11-13T08:40:00+08:00`, and no temporary file is left in the directory

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

### Requirement: A corrupt decision record leaves the mailbox untouched

When `junk_decisions.json` exists and is not valid JSON, or its top level is not an object, or its `senders` value is not an object, the SOP SHALL NOT ask, SHALL NOT move any mail and SHALL NOT write the file in that run. The report SHALL carry one line `junk_decisions_error` with the error name and SHALL list the mails in the junk mailbox. A missing file SHALL be treated as an empty record and SHALL NOT be an error.

#### Scenario: a corrupt record stops the rescue step

- **WHEN** the record file contains text that is not JSON
- **THEN** the rescue step lists the mails, reports the error name, and makes no tool call that changes the mailbox

##### Example: record loader results

| File content | senders | error |
| ------------ | ------- | ----- |
| (file missing) | `{}` | none |
| `{"version": "1.0", "senders": {}}` | `{}` | none |
| `{"version": "1.0"}` | `{}` | none |
| `not json` | none | `junk-decisions-not-json` |
| (empty file) | none | `junk-decisions-not-json` |
| `[]` | none | `junk-decisions-not-object` |
| `{"senders": []}` | none | `junk-decisions-senders-not-object` |
| `{"senders": null}` | none | `junk-decisions-senders-not-object` |

##### Example: an error plans no question and no move and refuses to write

- **GIVEN** two mails in the junk mailbox and the loader error `junk-decisions-not-json`
- **WHEN** the rescue plan is computed for an attended run and a write of `{"a@example.invalid": "rescue"}` is attempted
- **THEN** the senders to ask and the move group are empty, both mails are in the listed-only group with the reason `junk-decisions-not-json`, the write returns that error name, and the file content is unchanged

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

### Requirement: A stored sender decision is a consent source only for the rescue action

The confirmation rules SHALL list a fourth valid authorization source: a decision the user gave earlier in conversation and that the rescue step stored in the record file. The rule SHALL state that this source is valid only for moving that sender's mail from the junk mailbox to the inbox, that it cannot skip any other confirmation, that a record not written from the user's own answer (for example one brought in by a third-party clone) is not consent, and that an entry the user disowns is treated as absent.

#### Scenario: the rule names the fourth source and its limits

- **WHEN** the Provenance section of the confirmation rules is read
- **THEN** it lists four sources and the fourth is limited to the rescue action

##### Example: provenance lists the stored sender decision

- **GIVEN** the Provenance section of the confirmation-triggers rule
- **WHEN** its numbered list of valid sources is read
- **THEN** it has four items, the fourth names `junk_decisions.json`, limits it to moving mail from the junk mailbox to the inbox, and says a record from a third-party clone or a disowned entry is not consent
