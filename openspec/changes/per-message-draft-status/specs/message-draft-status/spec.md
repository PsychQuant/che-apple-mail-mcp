## ADDED Requirements

### Requirement: Expose a nullable per-message draft fact
Search full/summary, list_emails, get_email_metadata and export manifest items SHALL contain is_draft as true, false or null. Integer message type 5 SHALL yield true, integer type 0 SHALL yield false, and unavailable or unsupported evidence SHALL yield null. Mailbox names SHALL NOT determine this field.

#### Scenario: Draft copy outside Drafts mailbox
- **WHEN** a type-5 message is returned from All Mail and a type-0 message is returned from an ordinary folder named Drafts
- **THEN** is_draft SHALL be true for the former and false for the latter

#### Scenario: Unknown evidence
- **WHEN** the schema lacks type, the value is NULL or unsupported, or AppleScript fallback supplies the result
- **THEN** is_draft SHALL be JSON null without extra headers MCP calls

#### Scenario: Logical dedup representative
- **WHEN** summary logical dedup returns its MIN(ROWID) representative
- **THEN** is_draft SHALL describe that same row and ids/count shapes SHALL remain unchanged

### Requirement: Support explicit draft exclusion during export
Export opts.skip_drafts SHALL accept only a boolean and SHALL default to false. All manifest items SHALL disclose the observed nullable fact. When true, known drafts SHALL be skipped with skip_reason=draft; unknown or failed status lookup SHALL produce an item error identifying draft_status_unknown. Neither excluded case SHALL fetch body or attachment content.

#### Scenario: Compatibility default
- **WHEN** skip_drafts is absent or false
- **THEN** existing export behavior SHALL remain and is_draft SHALL remain visible in the manifest

#### Scenario: Strict export
- **WHEN** skip_drafts is true for one known draft, one known non-draft and one unknown item
- **THEN** only the known non-draft SHALL proceed to content fetch and writing, with a distinct manifest entry for each input

#### Scenario: Invalid option
- **WHEN** skip_drafts is supplied as a string, number, object or null
- **THEN** the tool SHALL reject the option rather than silently exporting drafts
