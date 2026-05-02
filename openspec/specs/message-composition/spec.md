# message-composition Specification

## Purpose

TBD - created by archiving change 'compose-tools-format-parameter'. Update Purpose after archive.

## Requirements

### Requirement: Composing tools accept a format parameter

The system SHALL provide four composing MCP tools — `compose_email`, `create_draft`, `reply_email`, and `forward_email` — each accepting an optional `format` parameter with permitted values `"plain"`, `"markdown"`, and `"html"`. When `format` is omitted or null, the system SHALL treat the request as `format: "plain"` to preserve backwards compatibility.

#### Scenario: Format parameter omitted defaults to plain

- **WHEN** a caller invokes `compose_email` with body `"Hi\n\n*Regards*"` and no `format` argument
- **THEN** the system SHALL deliver the email with the literal string `"Hi\n\n*Regards*"` as plain text
- **AND** the asterisks SHALL NOT be rendered as italic

#### Scenario: Invalid format value is rejected

- **WHEN** a caller invokes any composing tool with `format: "rtf"` (not a permitted value)
- **THEN** the system SHALL return an MCP error describing the permitted values `plain`, `markdown`, `html`
- **AND** the system SHALL NOT create, send, or draft the email

---
### Requirement: Plain mode preserves existing behavior

When `format` is `"plain"`, the system SHALL pass the `body` parameter as-is into the AppleScript `content` property of the outgoing message. HTML tags in the body SHALL appear literally in the delivered email; no HTML rendering SHALL occur.

#### Scenario: Plain mode preserves literal HTML tags

- **WHEN** a caller invokes `compose_email` with `body: "<b>bold</b>"` and `format: "plain"`
- **THEN** the recipient SHALL see the literal characters `<b>bold</b>` in the email body
- **AND** the text SHALL NOT be rendered as bold

---
### Requirement: Markdown mode renders via AttributedString

When `format` is `"markdown"`, the system SHALL parse `body` using Swift's `AttributedString(markdown:)` initializer and convert the resulting attributed string to HTML, then assign the HTML to the AppleScript `html content` property of the outgoing message. The system SHALL support at minimum the following markdown constructs: bold (`**text**`), italic (`*text*` or `_text_`), inline code (`` `text` ``), links (`[text](url)`), and unordered lists. Constructs outside this subset (e.g., tables, footnotes) SHALL be delegated to `AttributedString(markdown:)` best-effort rendering and SHALL NOT cause the tool to fail.

#### Scenario: Markdown bold and italic render correctly

- **WHEN** a caller invokes `compose_email` with `body: "**bold** and *italic*"` and `format: "markdown"`
- **THEN** the recipient SHALL see the word "bold" rendered with bold typography
- **AND** the word "italic" SHALL be rendered with italic typography
- **AND** the asterisks SHALL NOT appear in the delivered email

#### Scenario: Markdown link is clickable

- **WHEN** a caller invokes `compose_email` with `body: "See [example](https://example.com)"` and `format: "markdown"`
- **THEN** the delivered email SHALL contain a clickable hyperlink with visible text "example" and URL `https://example.com`

#### Scenario: Markdown parse failure surfaces as tool error

- **WHEN** a caller invokes a composing tool with malformed markdown that `AttributedString(markdown:)` cannot parse
- **THEN** the system SHALL return an MCP error describing the parse failure
- **AND** the system SHALL NOT send or draft the email

---
### Requirement: HTML mode writes body to AppleScript html content

When `format` is `"html"`, the system SHALL assign the `body` string directly to the AppleScript `html content` property of the outgoing message without parsing or transformation. The system SHALL NOT attempt to validate or sanitize the HTML.

#### Scenario: HTML body renders as rich text

- **WHEN** a caller invokes `compose_email` with `body: "<b>bold</b> <a href=\"https://example.com\">link</a>"` and `format: "html"`
- **THEN** the word "bold" SHALL be rendered with bold typography in the delivered email
- **AND** the text "link" SHALL be rendered as a clickable hyperlink to `https://example.com`

---
### Requirement: Reply and forward wrap original content in HTML blockquote

When `reply_email` or `forward_email` is invoked with `format` set to `"markdown"` or `"html"`, the system SHALL construct the outgoing message body such that the user-supplied body appears first (rendered per the format rules above), followed by an `<hr>` separator, followed by the original message content wrapped inside an HTML `<blockquote>` element. The system SHALL attempt to read `html content of originalMsg` via AppleScript first; when that read succeeds and returns non-empty content, the system SHALL place that HTML directly inside the blockquote. When the read is denied by the AppleScript runtime (a known macOS limitation — see Requirement: AppleScript html content read is denied on messages) or returns empty, the system SHALL HTML-escape the plain-text content of the original message, convert newlines to `<br>`, and place the result inside the blockquote.

#### Scenario: Reply composition uses original HTML when available

- **WHEN** `composeReplyHTML` is invoked with `userBody: "Thanks, noted."`, `userFormat: markdown`, `originalHTML: "<p>Can you review?</p>"`, and a non-empty `originalPlain`
- **THEN** the returned HTML SHALL contain `Thanks, noted.` rendered as a paragraph
- **AND** the HTML SHALL contain `<blockquote>` wrapping the content `<p>Can you review?</p>`

#### Scenario: Reply composition escapes plain text when original HTML unavailable

- **WHEN** `composeReplyHTML` is invoked with `userBody: "Thanks."`, `userFormat: markdown`, `originalHTML: nil`, and `originalPlain: "Can you <review>?"`
- **THEN** the returned HTML SHALL contain `<blockquote>`
- **AND** the blockquote content SHALL contain `Can you &lt;review&gt;?` (HTML-escaped)

#### Scenario: Reply in plain mode embeds RFC 3676 quoted original

- **WHEN** a caller invokes `reply_email` with `body: "Thanks"` and `format: "plain"` (or omits format)
- **THEN** the reply SHALL use the AppleScript `content` property
- **AND** the value SHALL be `"Thanks\n\n> <line 1 of original plain content>\n> <line 2>\n..."` — the user body, a blank line, then the original plain message with each line prefixed by `"> "` (greater-than + space) per RFC 3676 §4.5
- **AND** empty lines in the original SHALL be quoted as `">"` (no trailing space) per RFC 3676 §4.5 stuffing rule
- **AND** the reply SHALL NOT use the AppleScript `html content` property
- **AND** if the pre-fetch of original content fails (e.g. message deleted, sandbox denial), the reply SHALL gracefully degrade to the user body alone (no quoted block) rather than aborting the entire reply

> **Note (#43)**: Pre-v2.5.0 the plain branch used `set content to "<body>" & return & return & content`, which silently produced bare-body replies because Mail.app's outgoing-message `content` property is empty until the GUI compose pipeline materializes the quoted body. Replaced with Swift-side composition (`composeReplyPlainText`) that pre-fetches and quotes deterministically.

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

The MCP tool input schema for each of `compose_email`, `create_draft`, `reply_email`, and `forward_email` SHALL declare `format` as an optional string property with an enum constraint of `["plain", "markdown", "html"]` and a description stating the default is `"plain"`. The `format` property SHALL NOT appear in the `required` array of any tool schema.

#### Scenario: Tool schema advertises format enum

- **WHEN** an MCP client calls `tools/list`
- **THEN** the returned schema for each of the four composing tools SHALL include a `format` property
- **AND** the `format` property SHALL declare enum values exactly `["plain", "markdown", "html"]`
- **AND** the `format` property SHALL NOT be listed as required
