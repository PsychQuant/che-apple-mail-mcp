## ADDED Requirements

### Requirement: Discover candidates without asserting identity
Index paths SHALL supply candidates only. Parent/name/position agreement and legacy tuple paths SHALL NOT establish a special role. Component boundaries SHALL be preserved, and paths with unrepresentable literal slash components SHALL be omitted.

#### Scenario: Ordinary sibling names
- **WHEN** Projects/Drafts and Projects/Sent are the only matching index candidates
- **THEN** neither path SHALL be returned without a native role match

### Requirement: Confirm candidate identity through Mail
The system SHALL compare the exact account-scoped candidate mailbox with the uniquely matched native special-mailbox child, checking the expected leaf and each fixed-depth native container component of both objects, terminating at the exact account object. It SHALL validate counted versioned proof records and associate each record with exactly one candidate index.

#### Scenario: Unique native confirmation
- **WHEN** exactly one candidate for a role is positively confirmed
- **THEN** that role's path SHALL be returned

#### Scenario: Invalid or ambiguous proof
- **WHEN** proof is malformed, indexes are missing/duplicate/out of range, or multiple candidates for a role match
- **THEN** the affected paths SHALL NOT be asserted

### Requirement: Preserve optional-path degradation
Leaves and canonical account metadata SHALL survive index/proof unavailability. Unified mode SHALL remain unchanged. Empty candidate sets SHALL NOT trigger an additional native operation.

#### Scenario: Probe unavailable
- **WHEN** native verification fails or no index candidates exist
- **THEN** leaves SHALL remain available and unverified paths SHALL be absent
