# batch-operations Delta Specification

## ADDED Requirements

### Requirement: Export direction derived per email from sender identity

The `batch_export_emails_markdown` tool (and its deprecated alias `export_emails_markdown`) SHALL derive each exported email's frontmatter `direction` value **per email** from sender identity, not from the batch-level `mailbox` parameter, whenever the user's own email addresses are available. The derivation SHALL be:

- The system SHALL resolve the user's own-addresses set as the union of all configured accounts' email addresses resolvable from the local account mapping used by the SQLite index reader (no AppleScript round-trip). Addresses SHALL be compared as bare email addresses (display names stripped) using case-insensitive comparison.
- For each exported email, the system SHALL compare the email's bare sender address against the own-addresses set: a match SHALL yield `direction: sent`; a non-match SHALL yield `direction: received`.
- When the own-addresses set is empty or unavailable (e.g. Exchange/EWS accounts whose addresses are absent from the local mapping, or when the SQLite index reader is unavailable), the system SHALL fall back — for the whole batch — to the pre-existing mailbox-label heuristic (the `mailbox` parameter string containing a Sent-mailbox indicator yields `sent` for all items, otherwise `received` for all items). The export MUST NOT fail solely because own addresses cannot be resolved.
- Each manifest item whose `direction` was produced by the mailbox-label fallback SHALL carry `direction_inferred: true`. Manifest items whose `direction` was derived from sender identity SHALL NOT carry a `direction_inferred` field (negative-only disclosure, mirroring the existing `body_downloaded: false` convention).
- The frozen frontmatter contract SHALL be unchanged: exactly the same six core fields in the same order; only the correctness of the `direction` **value** changes.
- The `mailbox` tool-input parameter SHALL be documented as a mailbox scope/label whose role in direction is fallback-only; the tool description MUST NOT claim that the mailbox name is the primary source of `direction`.

#### Scenario: Gmail All Mail export labels own-sent messages as sent

- **WHEN** `batch_export_emails_markdown` exports three emails from a mailbox named `[Gmail]/全部郵件` while the own-addresses set contains `user@gmail.com`, where one email's sender is `user@gmail.com` and the other two emails' senders are other addresses
- **THEN** the file exported for the own-sender email SHALL contain `direction: sent`
- **AND** the files exported for the other two emails SHALL contain `direction: received`
- **AND** none of the three manifest items SHALL contain a `direction_inferred` field

#### Scenario: Sender comparison is case-insensitive on bare addresses

- **WHEN** an email whose `From` header is `"Che Cheng" <User@GMAIL.com>` is exported while the own-addresses set contains `user@gmail.com`
- **THEN** the exported file SHALL contain `direction: sent`

#### Scenario: Empty own-addresses set fails open to the mailbox-label heuristic with disclosure

- **WHEN** `batch_export_emails_markdown` exports two emails while the own-addresses set resolves as empty (e.g. every configured account is an EWS account whose address is absent from the local mapping), with `mailbox: "Sent Items"`
- **THEN** the export SHALL succeed and both files SHALL contain `direction: sent` (mailbox-label heuristic)
- **AND** both manifest items SHALL contain `direction_inferred: true`

#### Scenario: Fallback from a non-Sent mailbox label

- **WHEN** the own-addresses set is empty and the `mailbox` parameter is `INBOX`
- **THEN** every exported file SHALL contain `direction: received`
- **AND** every manifest item SHALL contain `direction_inferred: true`

#### Scenario: Frozen frontmatter contract is unchanged

- **WHEN** any email is exported under sender-identity derivation
- **THEN** the file's frontmatter SHALL contain exactly the six core fields (`message_id`, `thread_key`, `in_reply_to`, `date`, `sender`, `direction`) in that order, with no additional core field introduced by this change

##### Example: Direction decision table

| Own-addresses set | Sender (bare) | mailbox param | direction | direction_inferred |
| ----------------- | ------------- | ------------- | --------- | ------------------ |
| {user@gmail.com} | user@gmail.com | [Gmail]/全部郵件 | sent | (absent) |
| {user@gmail.com} | boss@corp.com | [Gmail]/全部郵件 | received | (absent) |
| {user@gmail.com} | User@Gmail.COM | INBOX | sent | (absent) |
| (empty) | anyone@x.com | Sent Items | sent | true |
| (empty) | anyone@x.com | INBOX | received | true |
