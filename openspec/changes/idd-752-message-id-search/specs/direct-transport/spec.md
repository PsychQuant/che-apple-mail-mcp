## MODIFIED Requirements

### Requirement: send_draft sends one existing draft and cannot write content

The `send_draft` tool SHALL accept exactly these arguments: `account_name`, `account_id`, `draft_id`, `subject_match` and `message_id`. A call that carries any other argument, including `body`, `to`, `cc`, `bcc` and `attachments`, SHALL be refused by name before any connection is opened. Exactly one of `draft_id`, `subject_match` and `message_id` SHALL be given. The tool SHALL select the draft in the account's drafts mailbox on the server: with `subject_match`, the drafts whose subject equals it exactly; with `draft_id`, the drafts whose Message-ID equals the Message-ID of that local message row; with `message_id`, the drafts whose Message-ID equals it, without reading the local store. A `message_id` longer than 998 octets, or that holds any character outside printable ASCII without space, or has no `@`, SHALL be refused by name before any connection is opened. With `draft_id` and `message_id` both Message-IDs are put in the form `<local@domain>` before they are compared, and the server is searched, in one command, for the Message-ID with its angle brackets or without them (`OR HEADER Message-ID "<local@domain>" HEADER Message-ID "local@domain"`): a server whose header search matches only the whole value finds the first, one that matches substrings also finds a header written without brackets; each hit is then compared in full, so a hit whose Message-ID only contains the one searched for does not count. An argument whose value is JSON null SHALL be refused by name. When both `account_id` and `account_name` are given and name different configured accounts, the call SHALL be refused. An empty `subject_match` selects the drafts whose subject is empty. Subjects and Message-IDs SHALL be compared scalar by scalar, not by Unicode canonical equivalence. A search hit whose envelope the server does not return SHALL make the call fail, since the match can then not be shown to be unique. The UID of the selected draft SHALL be used only while the drafts mailbox reports the UIDVALIDITY it had when the draft was found; otherwise the call SHALL stop. The draft fetched SHALL be refused unless it still has the Message-ID (and, with `subject_match`, the subject) of the search hit. The drafts mailbox SHALL be found as the Requirement "The drafts and sent mailboxes are found in a fixed order" states; when it is not found, the call SHALL be refused and nothing SHALL be submitted. When the selection matches no draft or more than one, the call SHALL be refused and nothing SHALL be submitted. The tool SHALL NOT run AppleScript, SHALL NOT require Mail to be running, and SHALL NOT modify the local Envelope Index or any `.emlx` file.

#### Scenario: An argument that could write content

- **WHEN** `send_draft` is called with `draft_id` and `body`
- **THEN** the call fails naming `body`, and no connection is opened

#### Scenario: Two drafts share the subject

- **WHEN** `send_draft` is called with a `subject_match` that equals the subject of two drafts on the server
- **THEN** the call fails saying two drafts matched, and nothing is submitted

#### Scenario: The draft is not on the server

- **WHEN** `send_draft` is called with a `draft_id` whose message row exists locally and no draft on the server carries its Message-ID
- **THEN** the call fails saying the draft is not on the server, and nothing is submitted

#### Scenario: A draft made by append_draft is sent with Mail closed

- **WHEN** `send_draft` is called with the `message_id` an `append_draft` call returned, while Mail is not running
- **THEN** that draft is selected on the server without reading the local store, and it is submitted as any selected draft is

#### Scenario: A server that matches only the whole Message-ID

- **WHEN** `send_draft` is called with a `message_id` and the server's `HEADER Message-ID` search finds a message only when given the value with its angle brackets
- **THEN** the draft is found, as it is on a server that matches substrings
