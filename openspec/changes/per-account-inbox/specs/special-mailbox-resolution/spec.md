## MODIFIED Requirements

### Requirement: Per-account special-mailbox name resolution

The `get_special_mailboxes` tool SHALL accept optional `account_id` and `account_name` parameters. When neither is supplied, it SHALL return the application-level unified special-mailbox names unchanged. When an account selector is supplied, it SHALL return that account's per-account special-mailbox real (localized / provider) names — inbox, drafts, sent, trash, and junk — resolved via the unified special mailbox's per-account child mailboxes (`inbox` resolution was deferred until a live multi-account check confirmed `every mailbox of inbox` exposes per-account children; the 2026-07-14 check (#249) confirmed it on 7/7 accounts, including a localized Exchange inbox name).

Special-mailbox names are Mail's AppleScript-model metadata; resolution SHALL be AppleScript-based (not the SQLite Envelope Index).

#### Scenario: No account selector returns unified names unchanged

- **WHEN** `get_special_mailboxes` is called with neither `account_id` nor `account_name` (or both empty)
- **THEN** the result SHALL be the unified names `{inbox, drafts, sent, trash, junk, outbox}`, byte-identical to the pre-change output

#### Scenario: account_id returns that account's special-mailbox real names

- **WHEN** `get_special_mailboxes` is called with a non-empty `account_id`
- **THEN** the result SHALL be a single object for that account containing `account_id`, `account_name`, and the real names of its `drafts`, `sent`, `trash`, and `junk`
- **AND** each special-mailbox name SHALL be resolved by matching `id of account of mb` against the supplied UUID across the corresponding unified special mailbox's children
- **AND** the result SHALL include a per-account `inbox` when the account has an inbox child (e.g. a localized Exchange `收件匣`), omitted otherwise (#249)

##### Example: Gmail + iCloud multi-account

- **GIVEN** a Gmail account (UUID `G`, localized special names `草稿` / `已寄出` / `垃圾桶` / `垃圾郵件`) and an iCloud account (UUID `I`, names `Drafts` / `Sent` / `Trash` / `Junk`)
- **WHEN** called with `account_id = G`
- **THEN** the result is `{account_id: G, account_name: …, inbox: "INBOX", drafts: "草稿", sent: "已寄出", trash: "垃圾桶", junk: "垃圾郵件"}` — NOT the iCloud names (#249: the live check shows Gmail's per-account inbox child is named `INBOX`; a localized example is the Exchange `收件匣`)

#### Scenario: Per-account inbox is resolved (deferral lifted by the #249 live check)

- **WHEN** `get_special_mailboxes` is called with an account selector
- **THEN** the result SHALL include the account's per-account `inbox` real name when present — the live multi-account check the previous deferral required has confirmed `every mailbox of inbox` exposes per-account children (#249)

#### Scenario: Email-form account_name is resolved to a UUID

- **WHEN** `get_special_mailboxes` is called with an email-form `account_name` and no `account_id`
- **THEN** the email SHALL be resolved to the account UUID via the shared account-mapping reverse lookup before matching (so an email that is not Mail's account description still resolves), consistent with the write-tool chokepoint normalization

#### Scenario: Unresolvable child mailbox is skipped, not fatal

- **WHEN** the unified special mailbox contains a child with no resolvable `account` property (e.g. an On-My-Mac / local container)
- **THEN** that child SHALL be skipped and resolution SHALL continue for the remaining children

#### Scenario: A special-mailbox type absent for the account is omitted

- **WHEN** the requested account has no child for a given special-mailbox type (e.g. no junk mailbox)
- **THEN** that key SHALL be omitted from the result object (the call SHALL NOT fail)

##### Example: POP account with no junk mailbox

- **GIVEN** an account (UUID `P`, account_name `Work`) that has drafts/sent/trash children but no junk child under the unified junk mailbox
- **WHEN** called with `account_id = P`
- **THEN** the result is `{account_id: "P", account_name: "Work", drafts: "Drafts", sent: "Sent", trash: "Trash"}` — the `junk` key is absent (not `null`, not an error)

#### Scenario: An account selector matching no account raises an actionable error

- **WHEN** a non-empty `account_id` / `account_name` is supplied but matches no account at all
- **THEN** the tool SHALL throw an actionable error directing the caller to `list_accounts` and explaining the account-description-vs-email namespace, mirroring the `list_drafts` no-match contract

#### Scenario: outbox stays unified in per-account mode

- **WHEN** an account selector is supplied
- **THEN** the per-account result SHALL NOT include a per-account `outbox` (the outbox is an application-level transient send queue with no per-account child)
