## MODIFIED Requirements

### Requirement: Direct-write path marks

When `create_draft` attempts the direct-write path with timing enabled, the system SHALL record a swift mark with `path` `direct` when the attempt starts (`enter`) and when each of these steps completes successfully, in this order: `eligibility` (eligibility passed), `version_gate` (Mail/macOS version accepted), `drafts_resolved` (the account identified and its Drafts mailbox matched to a path in the index), `writer_opened` (store opened for writing and the schema accepted), `inserted` (write committed), `trigger_spawn` (the upload request is about to be handed to the osascript transport), `trigger_sent` (upload request succeeded), `uploaded` (upload confirmed), `read_ensured` (the draft observed as read locally — a read status that cannot be read is not a confirmation). It SHALL always record a final `returned` mark when the attempt ends. A step that does not complete SHALL produce no row. `window_delay` and `step_delay` SHALL be empty, and `from_address_set` SHALL be `true` when `from_address` is non-empty and `false` otherwise.

With timing enabled, the upload-request script SHALL itself log these marks, which the system SHALL record with `source` `script` and `path` `direct` in the same segment, in this order: `trigger_script_start` (the script began running inside Mail), `trigger_listed` (Mail listed the new draft), `trigger_unread` (the draft's read status was set to unread), `trigger_read` (the draft's read status was set back to read). A script mark whose step does not complete SHALL produce no row. The system SHALL move these marks out of the process-wide capture buffer into the direct segment as soon as the upload request returns or fails, before recording `trigger_sent` or reversing the write, and SHALL leave marks with other labels in that buffer. The only line the marks add between the two read-status changes SHALL be the `trigger_unread` mark; no `delay` and no control flow SHALL be added there. With timing disabled, the upload-request script SHALL be byte-for-byte identical to the script generated without timing support.

The `outcome` of every direct-write row SHALL be one of the following values. This list is closed:

- `created` — the draft was written and Mail has it: the upload was confirmed, or the upload request failed but reversing the write showed that Mail had already uploaded the draft.
- `created:upload_pending` — the draft was written and is in Mail's Drafts, but its upload was not confirmed: the request succeeded and the wait ran out, or the request failed and the write could not be reversed.
- `fell_back:trigger` — the upload request failed and the write was reversed.
- `not_attempted:<code>` — the attempt ended without the draft reaching Mail and with nothing it wrote left behind (for `insert`, the write was begun and rolled back), where `<code>` is one of `format`, `attachments`, `ccOrBcc`, `noRecipient`, `displayName`, `unsupportedAddress`, `emptySubject`, `missingFromAddress`, `fromNotBare`, `version`, `account`, `index`, `drafts_unidentified`, `drafts_unmatched`, `writer_open`, `schema_drift`, `mailbox`, `sender`, `insert`.

When `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT` is not `1`, the system SHALL record no `direct` rows.

#### Scenario: An ineligible call records two direct rows

- **WHEN** `create_draft` is invoked with direct write enabled, timing enabled, and a non-empty `cc`
- **THEN** the call's `direct` rows SHALL be exactly `enter` and `returned`, in that order, each with `outcome` `not_attempted:ccOrBcc`

#### Scenario: A confirmed direct write records the trigger's sub-steps

- **WHEN** `create_draft` takes the direct-write path with timing enabled, the upload request succeeds and the upload is confirmed
- **THEN** the call's `direct` rows SHALL include, in time order, `inserted`, `trigger_spawn`, `trigger_script_start`, `trigger_listed`, `trigger_unread`, `trigger_read`, `trigger_sent` and `uploaded`
- **AND** the rows `trigger_script_start`, `trigger_listed`, `trigger_unread` and `trigger_read` SHALL have `source` `script`

#### Scenario: A draft Mail never lists records no later script marks

- **WHEN** the upload-request script ends with an error because Mail did not list the new draft
- **THEN** the call's `direct` rows SHALL include `trigger_spawn` and `trigger_script_start`
- **AND** SHALL include none of `trigger_listed`, `trigger_unread`, `trigger_read` or `trigger_sent`
- **AND** no mark labelled `trigger_` SHALL remain in the capture buffer after the attempt

#### Scenario: Timing disabled leaves the upload-request script unchanged

- **WHEN** the upload-request script is generated with timing disabled
- **THEN** it SHALL be byte-for-byte identical to the script generated without timing support
- **AND** it SHALL contain no `CHE_MAIL_TIMING|` mark
