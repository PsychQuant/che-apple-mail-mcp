## MODIFIED Requirements

### Requirement: Composing tools never inject a body via AppleScript

The system SHALL NOT assign an outgoing message's body through the AppleScript `content` property, the `html content` property, or a `content:` entry in `make new outgoing message with properties`. Apple Mail wraps any AppleScript-assigned body in `<blockquote type="cite">` at MIME serialization, which several mail clients render as a quotation of the sender's own text and which the sender cannot observe locally.

The system SHALL NOT insert an element into an outgoing message's `content` through the AppleScript object model, which includes `make new attachment … at after the last paragraph` told to the outgoing message. Such an insertion writes the message's `content`: on a reply whose body was pasted through Mail's editor, the object model's `content` holds neither the pasted body nor the quote built by Mail's `reply` verb, so the insertion leaves a message that contains only the inserted element (#534).

Every composing tool SHALL obtain its body from exactly one of two sources:

1. Mail's own editor — via the `mailto:` hand-off for `compose_email` / `create_draft`, and via the native reply/forward verb plus paste for `reply_email` / `forward_email`.
2. For `create_draft` only, and only under the conditions of Requirement: Direct-write draft path, a MIME message the system builds itself and writes into Mail's local store. This source SHALL NOT pass the body through any AppleScript property; the only AppleScript it runs on the draft changes the draft's read status.

No other body source is permitted.

#### Scenario: No composing path assigns content via AppleScript

- **WHEN** the AppleScript emitted by any composing tool is inspected, including the scripts the direct-write path runs
- **THEN** it SHALL contain no `set content`, no `set html content`, and no `content:` property in an outgoing-message construction
- **AND** it SHALL contain no `make new attachment`

#### Scenario: Object-model attachment insertion is absent from the source tree

- **WHEN** every Swift source file under `Sources/CheAppleMailMCP/` is scanned as text, comments included
- **THEN** no file SHALL contain `make new attachment`

#### Scenario: A successful compose produces an unwrapped body

- **WHEN** `create_draft` succeeds with `format: "plain"` through either body source
- **THEN** the saved draft's source SHALL NOT contain `<blockquote type="cite">` wrapping the supplied body

#### Scenario: The direct-write source is unavailable to the other composing tools

- **WHEN** `compose_email`, `reply_email`, or `forward_email` is invoked with `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1` set
- **THEN** the tool SHALL obtain its body from Mail's own editor exactly as it does with the variable unset

---

### Requirement: Ineligible composing calls fail without side effects

When a composing tool cannot use its non-injecting path, it SHALL fail with an error that names the reason and states an actionable alternative, and SHALL NOT create a draft, send mail, or delete an existing draft.

The set of ineligibility reasons SHALL be exactly the following nine, and SHALL NOT be extended by analogy. Reason 9 is temporary: it applies to `reply_email` only, and it SHALL be removed from this list when issue #608 (attaching through Mail's editor on the reply path) lands; it SHALL NOT be taken as a precedent for refusing any other tool or parameter. The reasons govern the GUI path; when `create_draft` creates the draft through Requirement: Direct-write draft path, reasons 3 and 8 do not apply, because that path sends no keystrokes. When the direct write does not create the draft, the GUI path's reasons apply in full.

1. `format` is `markdown` or `html`
2. the subject is empty (the clean path identifies its compose window by title)
3. Accessibility is not granted (GUI keystrokes are unavailable)
4. a supplied `from_address` is not a simple addr-spec
5. an attachment path contains non-ASCII characters
6. a `to`, `cc`, or `bcc` recipient carries a display name on a send (`compose_email`); on a draft, display-name recipients are filled through the GUI and are not a refusal reason
7. `signature` has mode `named` and the name is missing or not unique among Mail's signatures, refused before the mailto hand-off (#322)
8. the percent-encoded `mailto:` URL is longer than 8000 characters (`MAILTO_URL_TOO_LONG`), refused on the GUI path before any GUI operation, and for `compose_email` and `update_draft` before any Mail query (the direct write has no such limit); `check_compose_length` reports the exact total, body and overhead sizes
9. temporary, `reply_email` only (#534): `attachments` contains at least one path, in draft mode and in send mode alike, refused before any Mail action, attachment-file check or AppleScript, and before any window opens; argument parsing at the tool boundary (including the format refusal, reason 1) runs first; the error SHALL direct the caller to reply with `save_as_draft: true` and without `attachments`, then attach the file in Mail's compose window, and SHALL name #608

#### Scenario: Missing Accessibility fails and names the zero-TCC alternative

- **WHEN** `create_draft` is invoked while Accessibility is not granted and the direct-write path does not create the draft
- **THEN** the tool SHALL fail naming Accessibility as the reason
- **AND** the error SHALL name `open_mailto` as an alternative that requires no TCC grant, noting that it cannot carry attachments
- **AND** no draft SHALL be created

#### Scenario: Direct write needs no Accessibility

- **WHEN** `create_draft` is invoked with `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`, a call that passes every eligibility condition and every pre-write gate of Requirement: Direct-write draft path, Full Disk Access and Automation granted, and Accessibility not granted
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

#### Scenario: Reply with attachments fails before any Mail work

- **WHEN** `reply_email` is invoked with a non-empty `attachments` and with `format` omitted or `plain`
- **THEN** the tool SHALL fail naming reason 9
- **AND** the error SHALL direct the caller to save the reply as a draft without `attachments` and attach the file in Mail's compose window, and SHALL name #608
- **AND** no AppleScript SHALL run, no compose window SHALL open, no draft SHALL be created, and no mail SHALL be sent

##### Example: which reason a reply with attachments reports

| `attachments` | `save_as_draft` | `format` | Accessibility | Outcome |
| ------------- | --------------- | -------- | ------------- | ------- |
| `["/tmp/a.txt"]` | `true` | `plain` | granted | fails, reason 9 |
| `["/tmp/a.txt"]` | `false` | `plain` | granted | fails, reason 9 |
| `["/tmp/missing.pdf"]` | `true` | `plain` | granted | fails, reason 9 (not a missing-file error) |
| `["/tmp/a.txt"]` | `true` | `plain` | not granted | fails, reason 9 (before Accessibility) |
| `["/tmp/a.txt"]` | `true` | `markdown` | granted | fails, reason 1 (the format is parsed at the tool boundary first) |
| `[]` | `true` | `plain` | granted | not refused for reason 9 |
| omitted | `true` | `plain` | granted | not refused for reason 9 |

#### Scenario: Forward is unaffected by reason 9

- **WHEN** `forward_email` is invoked with a body, `format: "plain"`, and Accessibility granted
- **THEN** the tool SHALL NOT fail for reason 9
