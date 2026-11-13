## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: The sender address is the bracket group that ends the sender field

The recipe SHALL read a sender's address from the bracket group that ends the sender field, which is where the server writes it, or from the whole field when it has no brackets. A field whose display name contains a bracket, or contains an address different from the one in the final group, SHALL be treated as unreadable. An address that is not ASCII SHALL be treated as unreadable before any case folding. A mail whose sender is unreadable SHALL only be listed.

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

### Requirement: Nothing is changed for a mail whose rescue cannot be completed and checked

Before any call that changes the mailbox, the plan SHALL only list a mail that has no `id` or `account_name`, whose account has no known inbox, or for which no read-back search can be built (no subject, or a received time that is not an ISO 8601 time with an offset), each with its own reason. The recipe SHALL produce the arguments of the three calls for a mail, and SHALL produce none for a mail that is only listed.

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

##### Example: rescue calls for one mail

- **GIVEN** a mail with id `101`, account name `Example`, account id `g`, mailbox `[Gmail]/垃圾郵件`, subject `Statement`, received time `2026-10-16T06:32:19Z`, in an account whose `inbox_path` is `INBOX`
- **WHEN** the calls are produced
- **THEN** `mark_as_junk` gets id `101`, account name `Example`, account id `g`, mailbox `[Gmail]/垃圾郵件` and `is_junk` false; `move_email` gets the same id and account with `from_mailbox` `[Gmail]/垃圾郵件` and `to_mailbox` `INBOX`; the search gets query `Statement`, field `subject`, account name `Example`, `date_from` `2026-10-16T06:31:19Z`, `date_to` `2026-10-16T06:33:19Z`, projection `full` and limit 200

### Requirement: Recorded moves are shown before they happen and the question says what is remembered

With a person present, the rescue step SHALL list the mails it is about to move on a recorded decision, with the sender and the recorded time, before the first call that changes the mailbox. The rescue question SHALL state that the answer is stored for each sender, that later mail from those senders is handled without asking, and where the record can be edited.

#### Scenario: recorded moves are visible first

- **WHEN** an attended run has mail to move on a recorded `rescue` decision
- **THEN** the list of those mails is printed before `mark_as_junk` or `move_email` is called

##### Example: rescue step text shows recorded moves first

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it requires the list of mails moved by record to be printed before any call that changes the mailbox, and requires the question to say that the answer is remembered per sender and where to delete it

### Requirement: Registered archive targets are outside the rescue step

The archive-mail command SHALL state that the junk mailbox lines of the report and the rescue step apply only to runs that are not handed to the registered-target flow, and that the registered-target flow SHALL NOT call `mark_as_junk` or `move_email`.

#### Scenario: the limitation is stated where the hand-off happens

- **WHEN** the trust boundary section of the archive-mail command is read
- **THEN** it names the registered-target flow as a place where the two tools are never called

##### Example: trust boundary text excludes the registered-target flow

- **GIVEN** the Trust boundary section and the Step 9 section of the archive-mail command
- **WHEN** their text is read
- **THEN** the Trust boundary states that the flow handed to archive-mail-tree does not call the two tools, and Step 9 states that registered targets are not covered

### Requirement: A flag or a workspace setting never authorizes the rescue move

The confirmation rules SHALL state that a command flag and a workspace setting, the second and third authorization sources, do not authorize moving mail out of the junk mailbox.

#### Scenario: the rule scopes the other sources out

- **WHEN** the Provenance section of the confirmation rules is read
- **THEN** it states that sources two and three do not authorize the rescue move

##### Example: provenance scopes flags and settings out of the rescue

- **GIVEN** the Provenance section of the confirmation-triggers rule
- **WHEN** its text is read
- **THEN** it states that neither a command flag nor a workspace setting authorizes moving mail from the junk mailbox to the inbox

### Requirement: The rescue step follows a reconcile gate that passed

The archive-mail command SHALL state that the reconcile gate is the last step of the archive itself and that only the rescue step follows it, and that the rescue step does not run when the gate did not pass, in which case its task is closed with that reason.

#### Scenario: a failed gate leaves the mailbox untouched

- **WHEN** the reconcile gate does not pass
- **THEN** the rescue step does not run and no mail is asked about or moved

##### Example: step order text

- **GIVEN** the Step 8.5 and Step 9 sections of the archive-mail command
- **WHEN** their text is read
- **THEN** Step 8.5 no longer says it is the last thing of the run without naming Step 9, and Step 9 states that it does not run when the Step 8.5 gate did not pass

### Requirement: A failed record write is reported by name and never raises

Recording an answer SHALL return an error name for every write failure and SHALL NOT raise, including when an existing key cannot be encoded as UTF-8. The record SHALL be written as ASCII JSON.

#### Scenario: an old key with an unpaired surrogate does not break recording

- **WHEN** the existing record has a key that contains an unpaired surrogate
- **THEN** recording a new answer returns without raising and the file stays valid JSON

##### Example: recording beside an unencodable key

- **GIVEN** a valid record whose `senders` object has the key `"\ud800"` with a `leave` entry
- **WHEN** the decisions `{"new@example.invalid": "rescue"}` are recorded at `2026-11-13T08:40:00+08:00`
- **THEN** the call returns no error, the file is ASCII, it loads again without error, and it holds both keys
