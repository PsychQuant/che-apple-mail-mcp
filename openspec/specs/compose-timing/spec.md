# compose-timing Specification

## Purpose

Opt-in per-step timing of the composing paths, written as CSV, so that a slow or failed call can be traced to the step where it spent its time and so that the GUI and direct-write paths of `create_draft` can be compared on measured numbers.

## Requirements

### Requirement: Timing is opt-in and never affects the compose call

The system SHALL record compose timing only when the environment variable `CHE_MAIL_COMPOSE_TIMING_CSV` names a file path. When the variable is unset or empty, the AppleScript the composing tools generate SHALL be byte-for-byte identical to the script generated without timing support, and the system SHALL write no timing file. A failure to write timing rows SHALL be reported on stderr and SHALL NOT change the result or the error of the compose call. Each timing write SHALL either complete or give up within about one second of starting — including any wait for another write in the same process or for another process's file lock — so a compose call is never held longer than that by timing. A write that gives up loses only its own rows and prints a `compose timing:` line on stderr. A path that is not a regular file, or a non-empty file whose last byte cannot be read, SHALL be refused the same way.

#### Scenario: Unset variable produces the untimed script

- **WHEN** `create_draft` takes the GUI path with `CHE_MAIL_COMPOSE_TIMING_CSV` unset
- **THEN** the generated AppleScript SHALL contain no `CHE_MAIL_TIMING|` mark
- **AND** no timing file SHALL be created

#### Scenario: An unwritable timing file does not fail the call

- **WHEN** `CHE_MAIL_COMPOSE_TIMING_CSV` names a path inside a directory that does not exist and `create_draft` succeeds
- **THEN** the tool SHALL return its normal success result
- **AND** stderr SHALL contain a line beginning with `compose timing:`

---
### Requirement: Timing CSV layout

The timing file SHALL be CSV with exactly this header line:

`run_id,source,step,t_ref,ms_since_start,ms_since_prev,outcome,window_delay,step_delay,from_address_set,path`

The system SHALL write the header only when the file does not exist or is empty. Each timing mark SHALL produce one row. Within one `run_id`, rows SHALL be ordered by time; `ms_since_start` SHALL be measured from the earliest mark of that `run_id`, and `ms_since_prev` from the mark before it. `source` SHALL be `swift` for marks taken in the server process and `script` for marks logged by the AppleScript. `path` SHALL be `gui-mailto` for marks of the GUI mailto path and `direct` for marks of the direct-write path. No field SHALL contain a comma or a double quote. Apart from a write that gives up as described in Requirement: Timing is opt-in and never affects the compose call, concurrent writers to the same file — within one server process or across processes — SHALL NOT lose, duplicate, or truncate each other's rows, and the header SHALL be written exactly once. When a non-empty file's last line has no line break, one SHALL be written before the new rows.

#### Scenario: A new file starts with the header

- **WHEN** a composing call records timing into a path where no file exists
- **THEN** the file's first line SHALL equal the header above
- **AND** every following line SHALL have exactly 11 comma-separated fields

#### Scenario: A held file lock does not hold up the calls

- **WHEN** another process holds the timing file's lock and four calls write at the same time
- **THEN** each write SHALL give up within about one second of starting, with a `compose timing:` stderr line
- **AND** the calls SHALL NOT queue behind each other's waits

#### Scenario: A missing final line break is added before new rows

- **WHEN** the timing file holds only the header with no trailing line break and a call appends a row
- **THEN** the file SHALL contain the header and the new row on separate lines

#### Scenario: A non-regular file is refused

- **WHEN** `CHE_MAIL_COMPOSE_TIMING_CSV` names a FIFO
- **THEN** the write SHALL be refused with a `compose timing:` stderr line naming it as not a regular file
- **AND** the compose call SHALL NOT wait on it

#### Scenario: Concurrent writers keep every row

- **WHEN** 16 writers append two rows each to a new timing file at the same time
- **THEN** the file SHALL contain the header exactly once, as its first line
- **AND** it SHALL contain all 32 rows, none duplicated or truncated

---
### Requirement: Mismatched header is refused

When the timing file already exists, is non-empty, and its first line differs from the header in Requirement: Timing CSV layout, the system SHALL NOT append any row to it and SHALL write a line beginning with `compose timing:` to stderr that names the file and states that its header does not match.

#### Scenario: A file written by an earlier version is left untouched

- **WHEN** the timing file's first line is `run_id,source,step,t_ref,ms_since_start,ms_since_prev,outcome,window_delay,step_delay,from_address_set` and a composing call records timing
- **THEN** the file's contents SHALL be unchanged
- **AND** stderr SHALL contain a `compose timing:` line naming the header mismatch

---
### Requirement: GUI mailto path marks

When `compose_email`, `create_draft`, or `update_draft` (which builds its replacement through that path) runs the GUI mailto path with timing enabled, the system SHALL record swift marks `enter`, `spawn`, and `returned`, plus every mark the AppleScript logs, all with `path` `gui-mailto`. These rows SHALL have `outcome` `ok` when the GUI script succeeded and `error` when it failed; `window_delay` and `step_delay` SHALL hold the values of `CHE_MAIL_MAILTO_WINDOW_DELAY` and `CHE_MAIL_MAILTO_STEP_DELAY`, or `default` when unset; `from_address_set` SHALL be `true` or `false`.

#### Scenario: A GUI draft records its steps

- **WHEN** `create_draft` takes the GUI path with timing enabled and succeeds
- **THEN** the rows for that call SHALL include steps `enter`, `spawn`, `script_start`, `dispatched`, and `returned`, each with `path` `gui-mailto` and `outcome` `ok`

---
### Requirement: Direct-write path marks

When `create_draft` attempts the direct-write path with timing enabled, the system SHALL record a swift mark with `path` `direct` when the attempt starts (`enter`) and when each of these steps completes successfully, in this order: `eligibility` (eligibility passed), `version_gate` (Mail/macOS version accepted), `drafts_resolved` (the account identified and its Drafts mailbox matched to a path in the index), `writer_opened` (store opened for writing and the schema accepted), `inserted` (write committed), `trigger_sent` (upload request succeeded), `uploaded` (upload confirmed), `read_ensured` (the draft observed as read locally — a read status that cannot be read is not a confirmation). It SHALL always record a final `returned` mark when the attempt ends. A step that does not complete SHALL produce no row. `window_delay` and `step_delay` SHALL be empty, and `from_address_set` SHALL be `true` when `from_address` is non-empty and `false` otherwise.

The `outcome` of every direct-write row SHALL be one of the following values. This list is closed:

- `created` — the draft was written and Mail has it: the upload was confirmed, or the upload request failed but reversing the write showed that Mail had already uploaded the draft.
- `created:upload_pending` — the draft was written and is in Mail's Drafts, but its upload was not confirmed: the request succeeded and the wait ran out, or the request failed and the write could not be reversed.
- `fell_back:trigger` — the upload request failed and the write was reversed.
- `not_attempted:<code>` — the attempt ended without the draft reaching Mail and with nothing it wrote left behind (for `insert`, the write was begun and rolled back), where `<code>` is one of `format`, `attachments`, `ccOrBcc`, `noRecipient`, `displayName`, `unsupportedAddress`, `emptySubject`, `missingFromAddress`, `fromNotBare`, `version`, `account`, `index`, `drafts_unidentified`, `drafts_unmatched`, `writer_open`, `schema_drift`, `mailbox`, `sender`, `insert`.

When `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT` is not `1`, the system SHALL record no `direct` rows.

#### Scenario: An ineligible call records two direct rows

- **WHEN** `create_draft` is invoked with direct write enabled, timing enabled, and a non-empty `cc`
- **THEN** the call's `direct` rows SHALL be exactly `enter` and `returned`, in that order, each with `outcome` `not_attempted:ccOrBcc`

---
### Requirement: One run per create_draft call

Each `create_draft` call with timing enabled SHALL use a single `run_id` for all of its rows. When the direct-write attempt ends without creating the draft and the call continues on the GUI path, the `direct` rows and the `gui-mailto` rows SHALL share that `run_id`, and `ms_since_start` SHALL be measured from the direct path's `enter` mark across both segments. When the direct write creates the draft, the call SHALL have no `gui-mailto` rows.

#### Scenario: A fallback is one run with two segments

- **WHEN** a `create_draft` call's direct attempt ends with `not_attempted:version` and the GUI path then succeeds
- **THEN** all rows of the call SHALL have the same `run_id`
- **AND** the `direct` rows SHALL precede the `gui-mailto` rows
- **AND** the `gui-mailto` `returned` row's `ms_since_start` SHALL equal the time from the direct `enter` mark to the GUI `returned` mark
