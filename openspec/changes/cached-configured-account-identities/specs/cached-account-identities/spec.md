## ADDED Requirements

### Requirement: Read configured account identity metadata
The system SHALL obtain a counted versioned JSON snapshot of Mail account IDs and configured email addresses in one non-GUI metadata operation using an existing Automation grant. It SHALL validate record count, version, types and unique IDs. It SHALL NOT infer address completeness from login names or mailbox labels.

#### Scenario: EWS and configured aliases
- **WHEN** native metadata reports an EWS address and multiple addresses for another account
- **THEN** all valid declared addresses SHALL be available for sender matching without per-message Apple Events

#### Scenario: Partial or malformed metadata
- **WHEN** any address list is unavailable/empty/invalid or the snapshot is malformed
- **THEN** completeness SHALL NOT be asserted; malformed snapshot refresh SHALL fail and partial positive evidence SHALL remain explicitly incomplete

### Requirement: Cache and coalesce identity refresh
The cache SHALL use a 300-second success TTL, 60-second failure backoff and one refresh task per server. Waiting callers SHALL have a five-second shared wait budget independent of the Mail actor queue. Expired data SHALL NOT be returned as fresh.

#### Scenario: Timeout and late completion
- **WHEN** a refresh outlives the waiter budget
- **THEN** waiters SHALL receive unavailable state, subsequent requests SHALL NOT launch another flight, and a later success SHALL populate the cache

#### Scenario: Force refresh and cancellation
- **WHEN** refresh_identity is true or one waiting request is cancelled
- **THEN** force SHALL bypass cached/backoff results while coalescing active work, and cancellation SHALL remove only the cancelled waiter

### Requirement: Preserve truthful export direction
Native snapshot addresses SHALL replace the SQLite primary set on success. A non-match SHALL be treated as confident received only with complete native metadata and a represented message account. Fallback SQLite decisions SHALL carry direction_inferred. Manifests SHALL report identity_source and identity_complete, with cache age when available.

#### Scenario: Sender classification
- **WHEN** an alias matches native metadata, an external sender does not match complete metadata, or metadata is unavailable
- **THEN** the outcomes SHALL respectively be confident sent, confident received, or disclosed inferred output

#### Scenario: Existing export controls
- **WHEN** identity refresh is used together with skip_drafts, dedup or attachment options
- **THEN** those controls SHALL remain effective and cancelled waiters SHALL NOT proceed to export writes
