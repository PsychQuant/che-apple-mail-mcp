## MODIFIED Requirements

### Requirement: update_draft upsert tool

The system SHALL locate exactly one old draft, retaining its actual account identity, then create a replacement through the same mechanism as create_draft. Deletion SHALL require the same correlated receipt that verifies the replacement's creation identity and To/Cc/Bcc addresses. A new numeric id and equal subject SHALL NOT alone prove a replacement exists. The old draft SHALL be kept for not-found, ambiguous, unavailable, or mismatch outcomes. The system SHALL NOT modify the old draft in place.

#### Scenario: Successful upsert

- **WHEN** the replacement's shared receipt is correlated and all three address sets match
- **THEN** the system SHALL delete the originally selected row in its actual account and return deleted_old: true, the old id, and the create result

#### Scenario: Replacement is not confirmed

- **WHEN** no trustworthy correlated receipt is available, including an old draft re-saved under a new id
- **THEN** the system SHALL keep the old draft and report deleted_old: false without claiming that a replacement was confirmed

#### Scenario: Creation fails

- **WHEN** replacement creation throws before a successful create result
- **THEN** the system SHALL keep the old draft and propagate the creation error

#### Scenario: Delete fails after a verified replacement

- **WHEN** deleting the originally selected account/id/subject fails
- **THEN** the system SHALL return deleted_old: false and describe the observed failure without selecting another draft
- **AND** a missing original row SHALL NOT be described as proof that the logical old draft is gone or only the replacement remains

### Requirement: identify selector semantics

The `update_draft` tool SHALL accept an identify selector that is exactly one of `draft_id` (a numeric message id, validated by the same numeric-only rule as other id-taking tools) or `subject_match` (exact string equality against draft subjects — never substring or fuzzy matching), with an optional `account_name` (or `account_id` UUID, which takes precedence) to scope the search to one account's drafts. An explicitly empty `subject_match` SHALL be rejected as a parameter error (empty-subject drafts are targetable via `draft_id`).

#### Scenario: ambiguous subject match refused

- **WHEN** `subject_match` matches more than one draft (including same-subject drafts across accounts when `account_name` is omitted)
- **THEN** the system SHALL refuse without deleting or creating anything, and the error SHALL list the matched candidates as `{id, subject}` pairs so the caller can retry with `draft_id`

#### Scenario: zero matches refused

- **WHEN** the identify selector matches no draft
- **THEN** the system SHALL refuse without creating anything, naming the unmatched selector; a missing draft_id SHALL explain possible autosave or synchronization drift and direct the caller to re-list within the intended account scope or use an unchanged exact subject that is unique in that scope. The system SHALL NOT automatically switch selectors or create a new draft

#### Scenario: both or neither selector supplied

- **WHEN** the call supplies both `draft_id` and `subject_match`, or neither
- **THEN** the system SHALL reject the call with a parameter-validation error

### Requirement: list_drafts returns draft ids

The list_drafts tool SHALL return subject and numeric id pairs from the same listing invocation. The id SHALL be described as a transient row identifier that can change through autosave or synchronization before the next call. Callers SHALL retain account scope; an unchanged unique exact subject SHALL be described as an alternative content selector, not a permanent identity. Existing subject-only consumers SHALL continue to work.

#### Scenario: Paired snapshot

- **WHEN** an account's drafts are listed
- **THEN** every entry SHALL pair the subject and id from the same snapshot

#### Scenario: Transient id guidance

- **WHEN** the caller reads list_drafts or update_draft descriptions
- **THEN** the descriptions SHALL disclose id drift and the uniqueness/account limits of subject_match
