## ADDED Requirements

### Requirement: update_draft upsert tool

The system SHALL provide an `update_draft` MCP tool that replaces an existing draft by (1) locating it, (2) creating a replacement draft via the same mechanism and eligibility rules as `create_draft`, and (3) deleting the located old draft only after the replacement was created successfully (create-then-delete ordering). The tool SHALL NOT modify a draft in place.

#### Scenario: successful upsert

- **WHEN** `update_draft` is called with an `identify` selector matching exactly one existing draft and valid replacement content
- **THEN** the system SHALL create the replacement draft first, then delete the matched old draft, and return a result reporting `deleted_old: true`, the old draft id, and the create-path result (including any legacy-path disclosure suffix inherited from the create mechanism)

#### Scenario: replacement not confirmed — old draft kept

- **WHEN** the replacement-draft creation reports success but re-listing the drafts (covering the replacement's possible destination accounts) does not, within a brief poll, show a NEW draft id absent from the pre-create snapshot AND carrying the replacement's exact subject
- **THEN** the system SHALL NOT delete the old draft and SHALL return `deleted_old: false` with an explicit not-confirmed notice — a reported success without a landed draft is never treated as a receipt, and a concurrent draft with a DIFFERENT subject never stands in as one (a same-subject concurrent draft is indistinguishable without a create-path id — a documented limit)

#### Scenario: create fails — old draft untouched

- **WHEN** the replacement-draft creation fails for any reason
- **THEN** the system SHALL NOT delete the old draft and SHALL propagate the creation error

#### Scenario: delete fails after successful create

- **WHEN** the replacement draft was created successfully but deleting the old draft fails
- **THEN** the system SHALL NOT throw; it SHALL return `deleted_old: false` with a notice matched to what is actually known: a generic delete failure SHALL state that both drafts may now exist; a clean-scan not-found (the whole delete scope was scanned successfully and the old draft was absent) MAY state the old draft is confirmed absent; an incomplete scan SHALL state the old draft's state is unknown — the system SHALL NOT claim confirmed absence on any swallowed or partial-scan error

### Requirement: identify selector semantics

The `update_draft` tool SHALL accept an identify selector that is exactly one of `draft_id` (a numeric message id, validated by the same numeric-only rule as other id-taking tools) or `subject_match` (exact string equality against draft subjects — never substring or fuzzy matching), with an optional `account_name` (or `account_id` UUID, which takes precedence) to scope the search to one account's drafts. An explicitly empty `subject_match` SHALL be rejected as a parameter error (empty-subject drafts are targetable via `draft_id`).

#### Scenario: ambiguous subject match refused

- **WHEN** `subject_match` matches more than one draft (including same-subject drafts across accounts when `account_name` is omitted)
- **THEN** the system SHALL refuse without deleting or creating anything, and the error SHALL list the matched candidates as `{id, subject}` pairs so the caller can retry with `draft_id`

#### Scenario: zero matches refused

- **WHEN** the identify selector matches no draft
- **THEN** the system SHALL refuse without creating anything, stating that update requires an existing draft (the caller may use `create_draft` for a new one)

#### Scenario: both or neither selector supplied

- **WHEN** the call supplies both `draft_id` and `subject_match`, or neither
- **THEN** the system SHALL reject the call with a parameter-validation error

### Requirement: list_drafts returns draft ids

The `list_drafts` tool SHALL return, for each draft, both its `subject` and its numeric `id`, obtained in the same single AppleScript invocation that lists the subjects (no per-draft round-trips). The `id` field SHALL be usable directly as `update_draft`'s `draft_id` and `delete_email`'s `id`.

#### Scenario: id and subject pairing

- **WHEN** `list_drafts` runs against a drafts mailbox containing N drafts
- **THEN** the result SHALL contain N entries each carrying the draft's `subject` and `id`, paired from the same positional index of the AppleScript id/subject lists

#### Scenario: backward compatibility

- **WHEN** an existing consumer reads only the `subject` field of `list_drafts` results
- **THEN** its behavior SHALL be unchanged (the `id` field is additive)
