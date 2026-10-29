## MODIFIED Requirements

### Requirement: Draft recipient receipt verifies addresses after save

After saving any draft, including bare-address and To-only drafts, the system SHALL obtain a correlated-draft-receipt using the actual creation context. The same complete record SHALL supply identity and To/Cc/Bcc verification. Intended display names SHALL be removed before comparison; address-set comparison SHALL remain case-insensitive and order-insensitive. Only a uniquely correlated record with all three sets matching SHALL produce recipients_verified: true. A correlated record with a different set SHALL produce recipients_verified: false and a recipients_diff object containing to, cc, and bcc expected/found sets; the created draft SHALL be kept.

Not-found, ambiguous, and unavailable receipts SHALL produce recipients_verified: false with their explicit receipt status and SHALL NOT fabricate found-address differences. Read or parse failures SHALL NOT be reported as absence or definitive mismatch. The system SHALL retain the original created draft on receipt failure and SHALL NOT report the creation as failed solely because verification could not complete. Existing AX token checks SHALL remain required for GUI-filled lists.

The receipt SHALL be returned as a call-local value to updateDraft. The system SHALL NOT use a shared last-recipient-outcome property or a separate post-create ID read to decide deletion. updateDraft SHALL keep the old draft unless this same receipt confirms both creation identity and all expected addresses.

#### Scenario: All fields match

- **WHEN** a correlated saved draft contains the requested To, Cc, and Bcc address sets
- **THEN** the result SHALL include recipients_verified: true

#### Scenario: To-only mismatch

- **WHEN** a correlated draft has the expected Cc/Bcc but a different To set
- **THEN** the result SHALL include recipients_verified: false and the To difference, and SHALL keep the created draft

#### Scenario: Unavailable or ambiguous receipt

- **WHEN** scope, identity, reading, or decoding prevents a trustworthy record
- **THEN** the result SHALL state unavailable or ambiguous without recipient differences or an absence claim

#### Scenario: Bare-address draft

- **WHEN** a draft contains only bare recipient addresses
- **THEN** the system SHALL still obtain and compare the same complete receipt

#### Scenario: Update cannot verify the replacement

- **WHEN** the shared receipt is not verified for creation identity and all three address fields
- **THEN** updateDraft SHALL keep the old draft and report deleted_old: false
