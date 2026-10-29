## ADDED Requirements

### Requirement: Expose a nullable per-message draft fact
Search full/summary, list_emails, get_email_metadata and export manifest items SHALL contain is_draft as true, false or null. It SHALL be true when the message, or any message sharing its global message id, has integer type 5 or Mail's draft flag (bit 0x40 of `flags`). It SHALL be false only when the message's type is integer 0 and every piece of evidence is present and negative: the schema has the flag and global-message-id columns, the message has a global message id, and the message and every message sharing it have a non-NULL type other than 5, a non-NULL flag value without 0x40, and a mailbox whose name is known and is not a drafts-folder name in the reader's list. Mailbox names SHALL be read when the query runs, not when the reader opens. Otherwise it SHALL be null, including when the schema lacks the evidence columns and on the AppleScript fallback. A mailbox name SHALL NOT make is_draft true.

#### Scenario: Draft copy outside Drafts mailbox
- **WHEN** a type-5 message is returned from All Mail, and a type-0 message without the draft flag is returned from a folder named Drafts
- **THEN** is_draft SHALL be true for the former and null for the latter

#### Scenario: Server-synced draft
- **WHEN** a type-0 message has the draft flag, or a copy of it in another mailbox has the flag or type 5
- **THEN** is_draft SHALL be true

#### Scenario: Known non-draft
- **WHEN** a type-0 message has no draft flag, no copy has the flag or type 5, and neither it nor a copy is in a drafts-named folder
- **THEN** is_draft SHALL be false

#### Scenario: Unknown evidence
- **WHEN** the schema lacks type, flags or global_message_id, a value on the message or a copy is NULL or unsupported, a mailbox name is unknown, or AppleScript fallback supplies the result
- **THEN** is_draft SHALL be JSON null without extra headers MCP calls

#### Scenario: Folder created while the reader is open
- **WHEN** a folder named as drafts is created, or a folder is renamed to a drafts name, after the reader opened, and a type-0 message without the flag or a copy of it is in that folder
- **THEN** the next query SHALL report is_draft as null for that message

#### Scenario: Logical dedup representative
- **WHEN** summary logical dedup returns its MIN(ROWID) representative
- **THEN** is_draft SHALL describe that same row and ids/count shapes SHALL remain unchanged

### Requirement: Support explicit draft exclusion during export
Export opts.skip_drafts SHALL accept only a boolean and SHALL default to false. All manifest items SHALL disclose the observed nullable fact. When true, known drafts SHALL be recorded with status draft_skipped and skip_reason=draft, counted in a top-level drafts_skipped count separate from the Message-ID dedup's skipped count; unknown or failed status lookup SHALL produce an item error identifying draft_status_unknown and, for a failed lookup, its cause. Neither excluded case SHALL fetch body or attachment content. A skip_drafts argument outside opts, or an opts value that is neither an object nor null, SHALL be rejected; a null opts SHALL mean absent. Items excluded before content fetch MAY omit message_id.

#### Scenario: Compatibility default
- **WHEN** skip_drafts is absent or false
- **THEN** existing export behavior SHALL remain and is_draft SHALL remain visible in the manifest

#### Scenario: Strict export
- **WHEN** skip_drafts is true for one known draft, one known non-draft and one unknown item
- **THEN** only the known non-draft SHALL proceed to content fetch and writing, with a distinct manifest entry for each input

#### Scenario: Invalid option
- **WHEN** skip_drafts is supplied as a string, number, object or null
- **THEN** the tool SHALL reject the option rather than silently exporting drafts
