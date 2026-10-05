# message-composition Specification

## Purpose

TBD - created by archiving change 'compose-tools-format-parameter'. Update Purpose after archive.

## Requirements

### Requirement: Composing tools accept a format parameter

The system SHALL provide four composing MCP tools — `compose_email`, `create_draft`, `reply_email`, and `forward_email` — each accepting an optional `format` parameter whose only permitted value is `"plain"`. When `format` is omitted or null, the system SHALL treat the request as `format: "plain"`.

The system SHALL reject `format: "markdown"` and `format: "html"` with an error that names the removal and directs the caller to `"plain"`. Rich-text bodies are not representable on any non-injecting path, and every injecting path has been removed.

#### Scenario: Format parameter omitted defaults to plain

- **WHEN** a caller invokes `compose_email` with body `"Hi\n\n*Regards*"` and no `format` argument
- **THEN** the body SHALL be delivered verbatim, with `*Regards*` appearing literally

#### Scenario: Markdown is rejected with a named reason

- **WHEN** a caller invokes any composing tool with `format: "markdown"`
- **THEN** the tool SHALL fail with an error naming `markdown` as removed and directing the caller to `"plain"`
- **AND** no draft SHALL be created and no mail SHALL be sent

#### Scenario: HTML is rejected with a named reason

- **WHEN** a caller invokes any composing tool with `format: "html"`
- **THEN** the tool SHALL fail with an error naming `html` as removed and directing the caller to `"plain"`
- **AND** no draft SHALL be created and no mail SHALL be sent

#### Scenario: Invalid format value is rejected

- **WHEN** a caller invokes any composing tool with `format: "rtf"`
- **THEN** the tool SHALL fail with a validation error naming the permitted value

---
### Requirement: Plain mode preserves existing behavior

When `format` is `"plain"`, the system SHALL deliver the `body` parameter verbatim: HTML tags SHALL appear literally in the delivered email and no HTML rendering SHALL occur. The body SHALL reach the message through one of the two sources in Requirement: Composing tools never inject a body via AppleScript — Mail's own editor (the `mailto:` hand-off or the native reply/forward verb plus paste), or, for `create_draft` under Requirement: Direct-write draft path, a MIME message the system builds with the body HTML-escaped; on that path the `text/plain` part is empty and the body is carried in `text/html`, as in drafts Mail saves itself, and Mail's auto-inserted signature is not added — and SHALL NOT be assigned through the AppleScript `content` property, which is what produces the `<blockquote type="cite">` wrapper.

#### Scenario: Plain body is delivered literally

- **WHEN** a caller invokes `compose_email` with `body: "<b>bold</b>"` and `format: "plain"`
- **THEN** the delivered email SHALL show the characters `<b>bold</b>` literally

#### Scenario: Plain body written directly is escaped

- **WHEN** `create_draft` creates a draft through the direct-write path with `body: "<b>bold</b>"`
- **THEN** the draft's HTML part SHALL contain `&lt;b&gt;bold&lt;/b&gt;`, so the characters `<b>bold</b>` are shown literally

#### Scenario: Plain body is not assigned via AppleScript content

- **WHEN** the AppleScript emitted for a plain compose is inspected
- **THEN** it SHALL NOT assign the body through `content` or `html content`

---
### Requirement: Signature preservation is out of scope

Apple Mail.app automatically inserts the user's signature into a newly-composed outgoing message's body. The system SHALL NOT attempt to preserve this auto-inserted signature when `format` is `"markdown"` or `"html"`, because the system overwrites the `html content` property with the user-supplied body (rendered per format rules). Callers requiring signature preservation SHALL either use `format: "plain"` (which does not overwrite `html content`) or explicitly include the signature HTML in the `body` parameter when using `markdown` / `html` mode. This limitation stems from the same AppleScript read restriction documented below — the system cannot read Mail.app's auto-inserted signature HTML to append user content to it, only overwrite the entire `html content`. Issue #15's "Required Support #3 (signature / rich-text reply)" is therefore addressed only for the plain-mode backwards-compatible path; full rich-text signature preservation requires a different mechanism (e.g., MailKit extension) outside this capability's scope.

#### Scenario: Markdown-mode compose does not claim signature preservation

- **WHEN** a caller invokes `compose_email` with `body: "Hi"` and `format: "markdown"` while the user has a Mail.app signature configured
- **THEN** the delivered email's HTML body SHALL contain the rendered markdown
- **AND** the system SHALL NOT make any guarantee about whether the user's Mail.app signature appears before, after, or at all in the delivered email
- **AND** the tool's description SHALL NOT advertise signature preservation for non-plain modes

---
### Requirement: AppleScript html content read is denied on messages

On macOS 13+ (including macOS 26), Mail.app's AppleScript scripting interface denies read access to the `html content` property of both incoming (inbox) messages and outgoing (draft) messages, returning error -1723 ("Access not allowed") or -1728 ("No such element"). This is a system-level restriction, not a code defect. The system SHALL treat `html content` as write-only for outgoing messages and unavailable-for-read on all messages. Any implementation path that reads `html content of originalMsg` SHALL wrap the read in an AppleScript `try` block and treat access denial as equivalent to the property being empty — falling back to the plain-text path defined in Requirement: Reply and forward wrap original content in HTML blockquote.

#### Scenario: Fetch-original script degrades gracefully when html content unreadable

- **WHEN** the system runs `buildFetchOriginalContentScript` against an inbox message that has HTML content
- **AND** AppleScript denies `html content` read with error -1723 or -1728
- **THEN** the script SHALL return a result with the HTML portion empty
- **AND** the downstream reply/forward logic SHALL use the plain-text path with HTML-escape + blockquote wrapping

---
### Requirement: Composing tools input schema exposes format parameter

Each composing tool's input schema SHALL expose `format` as an optional string with an enum of exactly `["plain"]`, and SHALL describe it as the only supported body format. The schema SHALL NOT expose `require_wrapper_free`.

#### Scenario: Schema advertises the single permitted format

- **WHEN** any composing tool's schema is inspected
- **THEN** `format` SHALL be present with enum `["plain"]`
- **AND** `require_wrapper_free` SHALL be absent

---
### Requirement: From-scratch composing tools accept cc and bcc recipients

The `compose_email` and `create_draft` MCP tools SHALL each accept optional `cc` and `bcc` parameters, each an array of recipient strings. The `cc` and `bcc` properties SHALL NOT appear in the `required` array of either tool schema, and omitting them SHALL produce behavior identical to the single-recipient (`to`-only) path. Recipient strings supplied via `cc` / `bcc` SHALL be validated at the boundary identically to `to` recipients.

Bare addr-specs in `cc` / `bcc` SHALL ride the `mailto:` URL on both tools. A display-name form (`Name <addr>`) in `cc` / `bcc` SHALL be accepted by `create_draft` (and by `update_draft`, which reuses its mechanism) and filled through the AX-addressed field mechanism, because a `mailto:` URL carries only addr-spec per RFC 6068. A display-name form in any recipient list SHALL cause `compose_email` to fail per the ineligibility contract, because a fill that failed on a send would dispatch with missing recipients.

> `reply_email` instead exposes `cc_additional` (recipients added on top of those derived from `reply_all`) — a reply-context parameter with distinct semantics — and is not covered by this requirement. `forward_email` does not currently accept `cc` / `bcc`.

#### Scenario: create_draft schema advertises cc and bcc

- **WHEN** the `create_draft` tool schema is inspected
- **THEN** it SHALL expose optional `cc` and `bcc` array parameters

#### Scenario: Display-name cc is accepted on a draft

- **WHEN** `create_draft` is invoked with `cc: ["Name <a@b.co>"]`
- **THEN** the tool SHALL create the draft with `a@b.co` as a cc recipient displayed as `Name`
- **AND** the result SHALL include `recipients_verified`

#### Scenario: Display-name cc is refused on a send

- **WHEN** `compose_email` is invoked with `cc: ["Name <a@b.co>"]`
- **THEN** the tool SHALL fail per the ineligibility contract and send nothing

---
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

---
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

---
### Requirement: Runtime composing failures propagate without falling back

When a composing tool's non-injecting path fails **after** it has begun operating — a GUI keystroke that does not land, a paste that does not take, a send stage that errors — the system SHALL propagate the error to the caller and SHALL NOT retry the operation through any body-assigning path.

Such a failure is distinct from the pre-flight ineligibility contract: it occurs after side effects are possible, so the error message SHALL describe how far the operation progressed and SHALL NOT claim that nothing happened. The existing post-dispatch classification (which distinguishes a failure before dispatch from one after it, so a caller can tell whether retrying risks a duplicate) SHALL continue to govern retry safety.

#### Scenario: A mid-operation GUI failure surfaces rather than falling back

- **WHEN** a composing tool's clean path opens its window and a subsequent GUI step fails
- **THEN** the tool SHALL return an error describing the failure
- **AND** the tool SHALL NOT assign the body through AppleScript as a fallback

#### Scenario: A post-dispatch failure is not presented as a no-op

- **WHEN** a send-stage failure occurs after the message has been dispatched
- **THEN** the error SHALL retain its post-dispatch classification so the caller can tell that retrying risks sending twice
- **AND** the error SHALL NOT state that no mail was sent

---
### Requirement: Draft display-name recipients are filled through AX-addressed fields

When `create_draft` (or `update_draft`, which reuses its mechanism) receives a `to`, `cc`, or `bcc` list in which any entry carries a display name (`Name <addr>`), the system SHALL omit that entire list from the `mailto:` URL and SHALL fill it through the compose window's GUI. For each such list the system SHALL locate the address field by its Accessibility identifier — `Mail.toField`, `Mail.ccField`, or `Mail.bccField` — set keyboard focus on that field, paste the comma-joined recipient list from the clipboard, and press Tab to commit the tokens. The system SHALL NOT locate a field by Tab order and SHALL NOT assign the list through the field's AX value.

The field lookup SHALL be polled (the AX tree settles for a beat after the window opens) rather than judged on a single probe. After committing, the system SHALL read the field's child token elements and SHALL require (a) the token count to equal the number of recipients in that list and (b) for each recipient that carries a display name, that token's AX value to equal the display name. A bare address's token value SHALL NOT be compared: Mail renders an address that has a Contacts card as the card's name, so the token text is not an invariant — cc and bcc addresses are verified by the post-save receipt; `to` addresses are not receipt-verified (the count gate is their only check). Any count mismatch, any named-token mismatch, and any field that cannot be located, SHALL abort before the save keystroke, close only the compose window this call opened, and fail the call naming the field and the mismatch.

#### Scenario: Named cc recipients become tokens in the Cc field

- **WHEN** `create_draft` is invoked with `cc: ["王小明 <ming@example.com>", "b@example.com"]`
- **THEN** the compose window's `Mail.ccField` SHALL contain exactly two tokens
- **AND** the first token's AX value SHALL be `王小明`; the second token's value SHALL NOT be compared (it may render as a Contacts card name)
- **AND** the `mailto:` URL SHALL carry no `cc` parameter

#### Scenario: Missing address field aborts before save

- **WHEN** a display-name `cc` list is to be filled and no element with identifier `Mail.ccField` exists in the compose window
- **THEN** the call SHALL fail naming `Mail.ccField` as unlocatable
- **AND** no save keystroke SHALL be dispatched
- **AND** the compose window opened by this call SHALL be closed

#### Scenario: Token count mismatch aborts before save

- **WHEN** two named cc recipients are pasted and the `Mail.ccField` afterwards exposes one token
- **THEN** the call SHALL fail naming the expected count (2) and the observed count (1)
- **AND** no draft SHALL be created

##### Example: read-back expectations per recipient form

| Recipient as supplied | Expected token AX value |
| --- | --- |
| `王小明 <ming@example.com>` | `王小明` |
| `b@example.com` | (not compared — Mail may render a Contacts card name; the count still requires one token) |
| `"Doe, Jane" <jane@example.com>` | `Doe, Jane` |

---
### Requirement: Bcc field is revealed on demand and disclosed, not restored

When a display-name `bcc` list is to be filled and the compose window exposes no element with identifier `Mail.bccField`, the system SHALL click the item of the View menu whose name contains `密件副本` or `Bcc` — the View menu itself SHALL be identified only by the menu-bar name `顯示方式` or `View`, and on a Mail UI in another language the reveal SHALL fail cleanly with `BCCREVEAL` naming that limit rather than scan other menus (the Window menu lists window titles, including this window's subject) — then poll until `Mail.bccField` exists, bounded by the same deadline used for From-popup population. The system SHALL NOT attempt to hide the field again afterwards. When the field was revealed by this call, the success result SHALL include `bcc_field_revealed: true`. If the menu item cannot be found or the field does not appear before the deadline, the call SHALL fail naming the Bcc field as unrevealable, close only the compose window this call opened, and create no draft.

#### Scenario: Hidden Bcc field is revealed and left visible

- **WHEN** `create_draft` is invoked with `bcc: ["密件人 <bcc@example.org>"]` and the compose window has no `Mail.bccField`
- **THEN** the system SHALL click the View menu item for the Bcc address field
- **AND** SHALL fill `Mail.bccField` once it exists
- **AND** the result SHALL include `bcc_field_revealed: true`
- **AND** the system SHALL NOT click the menu item a second time

#### Scenario: Bcc field cannot be revealed

- **WHEN** the View menu contains no item whose name contains `密件副本` or `Bcc` (or the View menu cannot be identified by name)
- **THEN** the call SHALL fail naming the Bcc field as unrevealable
- **AND** no draft SHALL be created

---
### Requirement: Draft recipient receipt verifies addresses after save

When a draft was created with any display-name `cc` or `bcc` recipient, then after the save keystroke the system SHALL locate the new draft in the drafts mailbox by exact subject match (the same subject-match strategy as `update_draft`'s post-create id receipt — currently two independent reads; merging them is tracked in #409), read the address of every cc recipient and every bcc recipient, and compare each set with the addresses the caller supplied. When both sets match, the result SHALL include `recipients_verified: true`. When either set differs, or the draft cannot be located, the result SHALL include `recipients_verified: false` and a `recipients_diff` JSON object (`{"cc":{"expected":[…],"found":[…]},"bcc":{…}}`) listing, per field, the expected and found addresses; the draft SHALL be kept, and the call SHALL NOT be reported as failed. When the receipt script itself cannot run (timeout, Automation refusal, runtime error), the result SHALL include `recipients_verified: false` and `recipients_receipt: unavailable` with the reason, SHALL NOT claim the draft was not found, and SHALL NOT retry the failed script (only a not-found result is polled, because the save can land asynchronously). The AX token read-back and this receipt are both required: the read-back proves the fill landed, the receipt proves the addresses Mail stored.

`update_draft` SHALL gate its delete of the old draft on this receipt only after its post-create id receipt has confirmed the replacement exists: when the confirmed replacement's receipt reports a definitive mismatch, the old draft SHALL be kept and the result SHALL say `deleted_old: false` with a note that states what was observed, says the receipt identifies a draft by subject only, and SHALL NOT instruct the caller to delete anything; an unavailable or not-found receipt SHALL NOT gate the delete, and a phantom create SHALL keep being reported as unconfirmed rather than as a mismatch.

#### Scenario: Receipt matches

- **WHEN** a draft was created with `cc: ["王小明 <ming@example.com>"]` and the saved draft's cc recipient address is `ming@example.com`
- **THEN** the result SHALL include `recipients_verified: true`

#### Scenario: Receipt differs but the draft is kept

- **WHEN** a draft was created with `bcc: ["甲 <a@example.org>", "乙 <b@example.org>"]` and the saved draft's bcc recipient addresses are `a@example.org` only
- **THEN** the result SHALL include `recipients_verified: false`
- **AND** `recipients_diff.bcc.expected` SHALL be `["a@example.org", "b@example.org"]` and `recipients_diff.bcc.found` SHALL be `["a@example.org"]`
- **AND** the draft SHALL NOT be deleted

#### Scenario: Receipt script fails — reported as unavailable, not as absence

- **WHEN** the receipt script throws (for example the 45 s AppleScript deadline)
- **THEN** the result SHALL include `recipients_verified: false` and `recipients_receipt: unavailable`
- **AND** the result SHALL NOT say the draft was not found
- **AND** the script SHALL NOT be re-run

#### Scenario: update_draft keeps the old draft on a definitive mismatch

- **WHEN** `update_draft` created its replacement, its post-create id receipt confirmed a new id, and the confirmed replacement's recipient receipt reports a definitive mismatch
- **THEN** the old draft SHALL NOT be deleted
- **AND** the result SHALL include `deleted_old: false` and a note naming the recipient mismatch, stating that two drafts MAY exist and that the receipt identifies a draft by subject only

#### Scenario: update_draft reports a phantom create as unconfirmed, not as a mismatch

- **WHEN** `update_draft`'s post-create id receipt finds no new id (phantom create), even though the recipient receipt read a same-subject draft whose addresses differ from the request
- **THEN** the result SHALL say `deleted_old: false` with a "not confirmed" note
- **AND** SHALL NOT report a recipient mismatch

#### Scenario: Receipt not applicable to bare-address drafts

- **WHEN** a draft was created with `cc: ["b@example.com"]` and no display-name recipient in any list
- **THEN** the system SHALL NOT perform the recipient receipt
- **AND** the result SHALL NOT include `recipients_verified`

---
### Requirement: Compose-window cleanup dismisses the discard-draft sheet

When the clean compose path fails after its window has been identified and before its dispatch keystroke, and closes the compose window it opened with `saving no`, the system SHALL then check whether that window still exists with a sheet whose Accessibility identifier is `Mail.sendMessageAlert`. If so, and exactly one window carries the call's subject, the system SHALL click the sheet's button whose title is exactly `不儲存`, `Don't Save`, or `Don’t Save`, and SHALL confirm the window no longer exists. If more than one window carries the subject the system SHALL NOT click any sheet button. If the window still exists after this, the failure message SHALL additionally state that a compose window was left open and names its title. The system SHALL NOT click the sheet's save or cancel buttons. Failures that occur before the window is identified (a same-title window pre-existing, more than one new window, no new window) are outside this requirement and remain tracked by #333.

#### Scenario: Discard sheet is dismissed on abort

- **WHEN** a display-name fill aborts and `close saving no` leaves the compose window open behind a `Mail.sendMessageAlert` sheet
- **THEN** the system SHALL click the sheet's discard button
- **AND** the compose window SHALL no longer exist
- **AND** no draft with the call's subject SHALL exist in the drafts mailbox

#### Scenario: Window survives cleanup

- **WHEN** the discard button was clicked and the compose window still exists
- **THEN** the failure message SHALL name the window title and state that it was left open

---
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

After the write commits, the system SHALL ask Mail to upload the draft by toggling the draft's read status to unread and back to read. The upload request succeeds when that toggle completes without error. If it fails, the system SHALL reverse the write exactly and take the GUI path. If the write cannot be reversed because Mail has already uploaded the draft, the system SHALL report the draft as created and SHALL NOT take the GUI path. If it cannot be reversed for any other reason, the system SHALL report the draft as created with its upload pending, SHALL NOT claim that it was uploaded or when it will be, and SHALL NOT take the GUI path. Once the upload request has succeeded, the system SHALL NOT take the GUI path for that call, because doing so would create a second draft. A reversed direct write that continues on the GUI path is not a retry through a body-assigning path; Requirement: Runtime composing failures propagate without falling back continues to govern failures of the GUI path itself.

After the upload is confirmed, the system SHALL look at the draft's local read flag up to four times until it can be read. If a look shows the draft unread, the system SHALL re-assert its read status once and look again up to eight times. The tool result SHALL end with ` [note: the draft is uploaded but still shows as unread locally]` when no look after the re-assert shows it read but at least one shows it unread, and with ` [note: the draft is uploaded but its local read status could not be read]` when all four looks before any re-assert, or all eight looks after the re-assert, fail to read the flag.

The direct-write path SHALL NOT require Accessibility. It requires Full Disk Access, because it writes Mail's store, and Automation, because it toggles the draft's read status.

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

#### Scenario: A failed upload request that cannot be reversed is not reported as uploaded

- **WHEN** the upload request fails and reversing the write fails for a reason other than Mail having uploaded the draft
- **THEN** the system SHALL NOT take the GUI path
- **AND** the tool result SHALL state that the upload request failed and the write could not be reversed, and SHALL NOT state that the draft was uploaded

#### Scenario: Unreadable read status after the upload is reported as unknown

- **WHEN** the upload is confirmed, a look shows the draft unread, and every look after the re-assert fails to read the flag
- **THEN** the tool result SHALL end with ` [note: the draft is uploaded but its local read status could not be read]`
