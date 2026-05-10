## ADDED Requirements

### Requirement: Markdown mode honors opt-in URL scheme allowlist via `sanitize_links`

When `format` is `"markdown"`, the system SHALL accept an optional boolean parameter `sanitize_links` on each of the four composing tools (`compose_email`, `create_draft`, `reply_email`, `forward_email`). When `sanitize_links` is omitted or `false`, the system SHALL render markdown links exactly as `AttributedString(markdown:)` produces them — preserving every URL scheme. When `sanitize_links` is `true`, the system SHALL filter parsed link URLs against a closed allowlist of `{http, https, mailto, tel}` (compared case-insensitively against the URL's scheme component); any link whose scheme falls outside this set SHALL be rendered as plain text — the link's anchor text SHALL be preserved, but the surrounding `<a>` element SHALL be omitted from the emitted HTML. The `sanitize_links` parameter SHALL be a no-op when `format` is `"plain"` (no link parsing occurs) or `"html"` (caller-trusted raw HTML, per the existing "HTML mode writes body to AppleScript html content" requirement). The `sanitize_links` parameter SHALL NOT appear in the `required` array of any tool schema and SHALL default to `false` for backwards compatibility.

#### Scenario: Default-off preserves javascript: URL passthrough

- **WHEN** a caller invokes `compose_email` with `body: "[click](javascript:alert('xss'))"` and `format: "markdown"`, omitting `sanitize_links`
- **THEN** the rendered HTML SHALL contain `href="javascript:alert('xss')"` wrapped in an `<a>` element
- **AND** the anchor text SHALL be `click`
- **AND** the system SHALL NOT alter the URL or drop the anchor

#### Scenario: sanitize_links=true drops anchor on javascript: URL

- **WHEN** a caller invokes `compose_email` with `body: "[click](javascript:alert('xss'))"`, `format: "markdown"`, and `sanitize_links: true`
- **THEN** the rendered HTML SHALL NOT contain `href="javascript:`
- **AND** the rendered HTML SHALL NOT contain an `<a>` element wrapping the text `click`
- **AND** the literal text `click` SHALL be preserved in the rendered output

##### Example: bypass classes blocked under sanitize_links=true

| Input link in body                          | Expected emitted href                              | Notes                            |
| ------------------------------------------- | -------------------------------------------------- | -------------------------------- |
| `[x](javascript:alert(1))`                  | (no `<a>` element; literal `x` preserved)          | direct javascript:               |
| `[x](JaVaScRiPt:alert(1))`                  | (no `<a>` element; literal `x` preserved)          | case-mix, lowercased compare     |
| `[x](data:text/html,<script>alert(1)</script>)` | (no `<a>` element; literal `x` preserved)      | data: not in allowlist           |
| `[x](file:///etc/passwd)`                   | (no `<a>` element; literal `x` preserved)          | file: not in allowlist           |
| `[x](vbscript:msgbox(1))`                   | (no `<a>` element; literal `x` preserved)          | vbscript: not in allowlist       |

#### Scenario: sanitize_links=true preserves http, https, mailto, tel allowlist

- **WHEN** a caller invokes `compose_email` with `format: "markdown"` and `sanitize_links: true`, supplying a body with links across the allowlisted schemes
- **THEN** every allowlisted link SHALL render as a clickable `<a href="...">` element with the original URL preserved verbatim
- **AND** the anchor text SHALL match the markdown link's display text

##### Example: allowlist preservation

| Input link in body              | Expected behavior                                                           |
| ------------------------------- | --------------------------------------------------------------------------- |
| `[site](https://example.com/x)` | `<a href="https://example.com/x">site</a>` emitted                          |
| `[mail](mailto:foo@example.com)`| `<a href="mailto:foo@example.com">mail</a>` emitted                         |
| `[call](tel:+15551234)`         | `<a href="tel:+15551234">call</a>` emitted                                  |
| `[home](http://example.com/)`   | `<a href="http://example.com/">home</a>` emitted                            |

#### Scenario: sanitize_links is no-op in plain and html modes

- **WHEN** a caller invokes any composing tool with `format: "plain"` and `sanitize_links: true`
- **THEN** the system SHALL pass the body verbatim into the AppleScript `content` property
- **AND** the system SHALL NOT parse, transform, or filter URLs
- **WHEN** a caller invokes any composing tool with `format: "html"` and `sanitize_links: true`
- **THEN** the system SHALL assign the body verbatim to the AppleScript `html content` property
- **AND** the system SHALL NOT parse, transform, or filter URLs in the supplied HTML

#### Scenario: sanitize_links wiring contract holds end-to-end across all four composing tools

- **WHEN** a caller invokes `compose_email`, `create_draft`, `reply_email`, or `forward_email` with `format: "markdown"`, `sanitize_links: true`, and a body containing `[click](javascript:alert(1))`
- **THEN** the AppleScript text produced by the corresponding script-builder function (`buildComposeEmailScript`, `buildCreateDraftScript`, `buildReplyEmailScript`, `buildForwardEmailScript`) SHALL NOT contain the substring `href="javascript:`
- **AND** when the same call is made with `sanitize_links: false` (or omitted), the produced AppleScript text SHALL contain `href="javascript:`
- **AND** the contract SHALL be enforced by automated tests at the script-builder layer, ensuring that any future change which drops the `sanitizeLinks` parameter forwarding through the controller / builder / renderer chain will fail the test suite
