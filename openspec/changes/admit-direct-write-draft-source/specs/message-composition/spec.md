## MODIFIED Requirements

### Requirement: Composing tools never inject a body via AppleScript

The system SHALL NOT assign an outgoing message's body through the AppleScript `content` property, the `html content` property, or a `content:` entry in `make new outgoing message with properties`. Apple Mail wraps any AppleScript-assigned body in `<blockquote type="cite">` at MIME serialization, which several mail clients render as a quotation of the sender's own text and which the sender cannot observe locally.

Every composing tool SHALL obtain its body from exactly one of two sources:

1. Mail's own editor — via the `mailto:` hand-off for `compose_email` / `create_draft`, and via the native reply/forward verb plus paste for `reply_email` / `forward_email`.
2. For `create_draft` only, and only under the conditions of Requirement: Direct-write draft path, a MIME message the system builds itself and writes into Mail's local store. This source SHALL NOT pass the body through any AppleScript property; the only AppleScript it runs on the draft changes the draft's read status.

No other body source is permitted.

#### Scenario: No composing path assigns content via AppleScript

- **WHEN** the AppleScript emitted by any composing tool is inspected, including the scripts the direct-write path runs
- **THEN** it SHALL contain no `set content`, no `set html content`, and no `content:` property in an outgoing-message construction

#### Scenario: A successful compose produces an unwrapped body

- **WHEN** `create_draft` succeeds with `format: "plain"` through either body source
- **THEN** the saved draft's source SHALL NOT contain `<blockquote type="cite">` wrapping the supplied body

#### Scenario: The direct-write source is unavailable to the other composing tools

- **WHEN** `compose_email`, `reply_email`, or `forward_email` is invoked with `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1` set
- **THEN** the tool SHALL obtain its body from Mail's own editor exactly as it does with the variable unset

### Requirement: Plain mode preserves existing behavior

When `format` is `"plain"`, the system SHALL deliver the `body` parameter verbatim: HTML tags SHALL appear literally in the delivered email and no HTML rendering SHALL occur. The body SHALL reach the message through one of the two sources in Requirement: Composing tools never inject a body via AppleScript — Mail's own editor (the `mailto:` hand-off or the native reply/forward verb plus paste), or, for `create_draft` under Requirement: Direct-write draft path, a MIME message the system builds with the body HTML-escaped — and SHALL NOT be assigned through the AppleScript `content` property, which is what produces the `<blockquote type="cite">` wrapper.

#### Scenario: Plain body is delivered literally

- **WHEN** a caller invokes `compose_email` with `body: "<b>bold</b>"` and `format: "plain"`
- **THEN** the delivered email SHALL show the characters `<b>bold</b>` literally

#### Scenario: Plain body written directly is escaped

- **WHEN** `create_draft` creates a draft through the direct-write path with `body: "<b>bold</b>"`
- **THEN** the draft's HTML part SHALL contain `&lt;b&gt;bold&lt;/b&gt;`, so the characters `<b>bold</b>` are shown literally

#### Scenario: Plain body is not assigned via AppleScript content

- **WHEN** the AppleScript emitted for a plain compose is inspected
- **THEN** it SHALL NOT assign the body through `content` or `html content`

### Requirement: Ineligible composing calls fail without side effects

When a composing tool cannot use its non-injecting path, it SHALL fail with an error that names the reason and states an actionable alternative, and SHALL NOT create a draft, send mail, or delete an existing draft.

The set of ineligibility reasons SHALL be exactly the following six, and SHALL NOT be extended by analogy. They govern the GUI path; when `create_draft` creates the draft through Requirement: Direct-write draft path, reason 3 does not apply, because that path sends no keystrokes. When the direct write does not create the draft, the GUI path's reasons apply in full.

1. `format` is `markdown` or `html`
2. the subject is empty (the clean path identifies its compose window by title)
3. Accessibility is not granted (GUI keystrokes are unavailable)
4. a supplied `from_address` is not a simple addr-spec
5. an attachment path contains non-ASCII characters
6. a `to`, `cc`, or `bcc` recipient carries a display name on a send (`compose_email`); on a draft, display-name recipients are filled through the GUI and are not a refusal reason

#### Scenario: Missing Accessibility fails and names the zero-TCC alternative

- **WHEN** `create_draft` is invoked while Accessibility is not granted and the direct-write path does not create the draft
- **THEN** the tool SHALL fail naming Accessibility as the reason
- **AND** the error SHALL name `open_mailto` as an alternative that requires no TCC grant, noting that it cannot carry attachments
- **AND** no draft SHALL be created

#### Scenario: Direct write needs no Accessibility

- **WHEN** `create_draft` is invoked with `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`, a call eligible for the direct-write path, and Accessibility not granted
- **THEN** the draft SHALL be created through the direct-write path
- **AND** the tool SHALL NOT fail for reason 3

#### Scenario: Non-ASCII attachment path fails with the manual recipe

- **WHEN** `create_draft` is invoked with an attachment path containing non-ASCII characters
- **THEN** the tool SHALL fail naming the path as the reason
- **AND** the error SHALL direct the caller to create the draft without `attachments` and attach the file manually
- **AND** no draft SHALL be created

#### Scenario: Display-name recipient on a send fails rather than degrading silently

- **WHEN** `compose_email` is invoked with `cc: ["王小明 <ming@example.com>"]`
- **THEN** the tool SHALL fail naming display-name recipients on a send as the reason
- **AND** the error SHALL direct the caller to `create_draft`, where display-name recipients are supported
- **AND** no mail SHALL be sent

#### Scenario: Display-name recipient on a draft is not a refusal reason

- **WHEN** `create_draft` is invoked with `bcc: ["王小明 <ming@example.com>"]` and every other eligibility condition holds
- **THEN** the tool SHALL NOT fail for reason 6
- **AND** SHALL proceed to fill the Bcc field

## ADDED Requirements

### Requirement: Direct-write draft path

When the environment variable `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT` equals `1`, `create_draft` SHALL first attempt to create the draft by writing it directly into Mail's local store (the Envelope Index and an `.emlx` file) and then asking Mail to upload it. When the variable is unset or has any other value, `create_draft` SHALL NOT attempt the direct write and its result SHALL carry no note about it.

Before writing anything, the system SHALL check eligibility. The call is ineligible, and SHALL take the GUI path, when any of the following holds. This list is closed; no other condition makes a call ineligible at this stage:

1. `format` is not `plain`.
2. `attachments` is non-empty.
3. `cc` or `bcc` is non-empty.
4. `to` is empty.
5. A `to` entry carries a display name.
6. A `to` entry is not a plain addr-spec.
7. `subject` is empty.
8. `from_address` is absent or empty.
9. `from_address` is not a bare addr-spec.

After eligibility passes and before writing, the system SHALL also require all of the following, checked in this order, and SHALL take the GUI path at the first that fails: (1) Mail's version is 16.x and the macOS major version is 27; (2) `from_address` maps to exactly one Mail account; (3) the Envelope Index is readable; (4) the account's Drafts mailbox is identified and matched to a mailbox path in the index; (5) the store opens for writing; (6) the store's `messages` columns equal the verified set and every other table it writes has its required columns; (7) that Drafts path corresponds to exactly one mailbox row and its URL is an IMAP URL; (8) a sender address row already exists for `from_address` in that account.

The write SHALL happen inside a single `BEGIN IMMEDIATE` transaction, with the `.emlx` file renamed into place inside that transaction. A failure during the write SHALL roll the transaction back and remove the file, and the call SHALL take the GUI path.

After the write commits, the system SHALL ask Mail to upload the draft by toggling the draft's read status to unread and back to read. If that request fails, the system SHALL reverse the write exactly and take the GUI path — unless Mail has already uploaded the draft, in which case the system SHALL NOT reverse it and SHALL report the draft as created. Once the upload request has succeeded, the system SHALL NOT take the GUI path for that call, because doing so would create a second draft.

Whenever the call takes the GUI path after the direct write was attempted or found ineligible (other than the variable being unset), the tool result SHALL end with ` [experimental direct-write not used: <reason> — GUI path]`, where `<reason>` names the condition that failed.

#### Scenario: Variable unset leaves create_draft unchanged

- **WHEN** `create_draft` is invoked with `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT` unset
- **THEN** the system SHALL NOT open the store for writing
- **AND** the tool result SHALL NOT contain `experimental direct-write`

#### Scenario: An ineligible call names its reason and writes nothing

- **WHEN** `create_draft` is invoked with the variable set to `1` and a non-empty `cc`
- **THEN** the system SHALL NOT open the store for writing
- **AND** the draft SHALL be created through the GUI path
- **AND** the tool result SHALL end with ` [experimental direct-write not used: cc/bcc are not written directly — GUI path]`

#### Scenario: A failed upload request reverses the write

- **WHEN** the direct write commits and the request asking Mail to upload the draft fails before Mail has uploaded it
- **THEN** the system SHALL delete every row and the `.emlx` file the write created
- **AND** the draft SHALL be created through the GUI path

#### Scenario: No fallback after the upload request succeeds

- **WHEN** the upload request succeeds but the upload is not confirmed within the wait
- **THEN** the system SHALL NOT take the GUI path
- **AND** the tool result SHALL state that the draft is in Mail's Drafts with its upload pending
