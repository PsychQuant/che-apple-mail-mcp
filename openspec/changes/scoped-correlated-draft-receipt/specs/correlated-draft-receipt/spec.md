## ADDED Requirements

### Requirement: Trusted creation context scopes the receipt

The system SHALL obtain the actual destination account and a creation binding from the compose operation before reading recipient addresses. A requested sender, an exact subject, a maximum numeric id, or membership outside a pre-create id set SHALL NOT alone establish this binding. Pre-create identifiers SHALL retain their account scope. Missing or unproven context SHALL produce unavailable before any recipient query; the system SHALL NOT fall back to reading recipient addresses across accounts.

#### Scenario: Missing destination evidence

- **WHEN** the compose operation has not established its actual account or creation binding
- **THEN** the receipt SHALL be unavailable and no recipient-address query SHALL run

#### Scenario: Old draft receives a new row id

- **WHEN** a pre-existing draft is re-saved under an id absent from the baseline during a phantom create
- **THEN** the re-saved draft SHALL NOT satisfy creation identity and SHALL NOT authorize deletion

#### Scenario: Unrelated account shares the subject

- **WHEN** account B contains the same subject as a creation bound to account A
- **THEN** the receipt SHALL NOT read or disclose account B's recipient addresses

### Requirement: One complete scoped read supplies identity and addresses

Each receipt attempt SHALL use one script to locate the uniquely bound draft and return its account id, numeric row id, subject, and To/Cc/Bcc address lists. Candidate metadata SHALL be completely validated before addresses are read. Baseline ids SHALL be excluded within their account scope. The bound candidate subject SHALL equal the requested subject before recipient addresses are read; a changed subject SHALL produce unavailable rather than a verified receipt. More than one matching candidate SHALL be ambiguous and SHALL NOT disclose candidate addresses. Any enumeration, metadata, or address-read failure SHALL make the whole receipt unavailable. Only a complete not-found result SHALL be polled, at most three attempts with 0.4 seconds between attempts; failed or ambiguous reads SHALL NOT be retried.

#### Scenario: Unique bound draft

- **WHEN** one draft satisfies the trusted binding and exclusion rules
- **THEN** a single read SHALL return that draft's identity and all three address lists

#### Scenario: Ambiguous bound candidates

- **WHEN** more than one candidate satisfies the lookup
- **THEN** the result SHALL be ambiguous without any candidate-address payload

#### Scenario: Bound draft subject changed

- **WHEN** the bound draft subject differs from the requested subject
- **THEN** the result SHALL be unavailable without reading its recipient addresses

#### Scenario: Partial scan failure

- **WHEN** any candidate metadata or recipient property cannot be read
- **THEN** the entire receipt SHALL be unavailable without a partial match or retry

### Requirement: Receipt payloads are strictly decoded

The internal payload SHALL be one JSON object whose version is exactly the string "1", with status found, not_found, ambiguous, or unavailable. Found SHALL contain account_id, id, subject, to, cc, and bcc with the documented types; id SHALL be a non-empty ASCII-numeric string and account_id SHALL match the trusted context. Other statuses SHALL carry only their status-specific fields. Ambiguous candidate_count SHALL be a canonical ASCII decimal string representing an integer from 2 through 9223372036854775807, without leading zeros. Numeric JSON tokens, decimal strings, and exponent strings SHALL be rejected for version and candidate_count; validation SHALL NOT depend on a previously rounded number. Unknown fields, unknown versions or statuses, missing fields, wrong types, wrong scope, or malformed JSON SHALL produce unavailable, not mismatch. Invalid raw payloads SHALL NOT be echoed in user results or logs.

#### Scenario: Broken payload

- **WHEN** the reader returns `malformed receipt` or a found object missing bcc
- **THEN** decoding SHALL produce unavailable and SHALL NOT report a definitive recipient mismatch

##### Example: Wire validation boundaries

| Payload | Expected outcome |
| --- | --- |
| version=true, status=not_found | unavailable: invalid_payload |
| found with id="١٠٢" | unavailable: invalid_payload |
| ambiguous with candidate_count="2" | ambiguous |
| ambiguous with candidate_count=2.5 | unavailable: invalid_payload |
| not_found with an extra to array | unavailable: invalid_payload |

#### Scenario: Wrong account payload

- **WHEN** a found payload names account B while the trusted context names account A
- **THEN** decoding SHALL reject it without disclosing its addresses

### Requirement: Creation adapter has live evidence before completion

The implementation SHALL demonstrate its account and creation-binding adapter on a real owned draft before this change is declared complete. Evidence SHALL include a successful same-subject update, actual re-save, explicit and default sender selection, and competing-draft cases. Unchanged snapshots, mock-only adapters, or permanent refusal of normal same-subject updates SHALL NOT satisfy this gate. Test drafts SHALL remain unsent and their owned artifacts SHALL be cleaned up.

#### Scenario: GUI evidence cannot be obtained

- **WHEN** the desktop cannot expose the owned compose window for the controlled experiment
- **THEN** the live gate SHALL remain incomplete and the change SHALL NOT be declared verified
