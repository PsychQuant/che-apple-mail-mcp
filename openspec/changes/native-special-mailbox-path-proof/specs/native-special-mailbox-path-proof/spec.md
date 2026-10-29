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

### Requirement: The direct-write draft path uses the same proof
When the opt-in direct-write draft path identifies the Drafts mailbox, it SHALL take the write target from the Drafts candidate the native proof confirmed, using that candidate's path components, and SHALL NOT look the path string up again. It SHALL submit only Drafts candidates to the proof. A proof that cannot run SHALL make the call take the GUI path with the reason `drafts_unidentified`; a proof that ran but confirmed no Drafts candidate, or no candidate at all, SHALL make it take the GUI path with `drafts_unmatched`. Both happen before any store is opened for writing.

#### Scenario: Proof unavailable before a direct write
- **WHEN** the proof script fails or times out
- **THEN** no store is opened for writing and the call takes the GUI path noting `drafts_unidentified`

#### Scenario: Two mailboxes share a path string
- **WHEN** the index holds a nested `Projects` → `Drafts` mailbox and a top-level mailbox literally named `Projects/Drafts`, and Mail confirms the nested one
- **THEN** the write targets the components `Projects`, `Drafts`

