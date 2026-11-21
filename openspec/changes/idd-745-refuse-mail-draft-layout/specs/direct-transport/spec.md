## MODIFIED Requirements

### Requirement: A draft is checked before it is submitted

Before submission the tool SHALL check the draft it fetched from the server, in this order, and SHALL refuse the call at the first check that fails, submitting nothing and leaving the draft in place:

1. The draft has exactly one Message-ID header, made of printable ASCII, and it is the Message-ID the server's envelope reports.
2. The record of sent drafts holds no entry for that Message-ID in the state `attempting`, `unknown` or `submitted` with nothing pending. (An entry in the state `submitted` with a stage pending is completed instead; see the requirement on stages after submission.)
3. The From field names exactly one address and holds no text that is not an address, and that address equals the configured `address` or one of `allowed_from`, compared without regard to ASCII letter case.
4. To, Cc and Bcc together name at least one address, none of them holds text that is not an address, and From, To, Cc and Bcc each appear at most once and From exactly once; each is blank, an empty group (`name:;`), or a list whose every comma-separated element (outside quoted strings, comments and angle brackets) holds exactly one address, and names as many addresses as the server's envelope reports for it. No text the server reports for the draft (Message-ID, subject, addresses) holds the account password in any form a login sends it.
5. Every line of the header section, the blank line that ends it included, ends in CRLF; the header section holds no `Resent-Bcc` field; and every line of it can be told to be, or not to be, part of a `Bcc` field.
6. The draft is not in Mail's draft layout: no header field named `X-Uniform-Type-Identifier` (compared without regard to ASCII letter case) whose value, unfolded and trimmed, is `com.apple.mail-draft` (compared the same way). The refusal names the field and says that a draft made with `append_draft` can be sent, or that the draft can be sent from Mail. This check applies to a new submission only: an entry in the state `submitted` with a stage pending is completed whatever the draft's layout.

#### Scenario: The sender is not the account's

- **WHEN** the selected draft's From address is neither the configured `address` nor in `allowed_from`
- **THEN** the call fails naming the From address, nothing is submitted, and the draft stays on the server

#### Scenario: The draft was already sent

- **WHEN** the record of sent drafts holds the draft's Message-ID in the state `submitted` with nothing pending
- **THEN** the call fails saying the draft was already submitted and when, and nothing is submitted

#### Scenario: A draft Mail saved

- **WHEN** the selected draft carries `X-Uniform-Type-Identifier: com.apple.mail-draft`
- **THEN** the call fails saying the draft is in Mail's draft layout and naming `append_draft`, no SMTP connection is opened, no entry is written, and the draft stays on the server
