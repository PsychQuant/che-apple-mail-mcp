## ADDED Requirements

### Requirement: append_draft creates one new draft on the server and builds it itself

The `append_draft` tool SHALL accept exactly these arguments: `account_name`, `account_id`, `to`, `cc`, `bcc`, `subject`, `body` and `from_name`. A call that carries any other argument, including `attachments`, `format` and `from_address`, SHALL be refused by name before any connection is opened. `to`, `cc` and `bcc` SHALL be lists of strings, absent meaning empty; `subject`, `body`, `from_name`, `account_name` and `account_id` SHALL be strings; a value of another type, JSON null included, SHALL be refused by name. `subject` and `body` SHALL be given, and `subject` SHALL NOT be empty. There SHALL be at least one recipient in `to`, `cc` and `bcc` together. Every recipient SHALL be a bare address of this form: a dot-atom local part (RFC 5322 `atext` characters and single dots, not first or last) of at most 64 octets, `@`, and a domain of at least two dot-separated labels, each 1 to 63 ASCII letters, digits or hyphens and not starting or ending with a hyphen; at most 254 octets in all. Anything else, a display name, a quoted local part, a domain literal and non-ASCII included, SHALL be refused. `subject` and `from_name` SHALL NOT hold a control character (below U+0020, or U+007F), and `body` SHALL NOT hold NUL. These checks SHALL happen before the configuration is read and before any connection is opened. The account SHALL be chosen and refused as `send_draft` chooses and refuses it, and the credential and the connection SHALL follow the requirements that apply to `send_draft`; the tool SHALL NOT connect to the SMTP server. The tool SHALL carry the same MCP annotations as `create_draft`: not read-only, not destructive, not idempotent, open world.

The tool SHALL build the whole message: header fields `From` (the account's address, with `from_name` as display name when it is given and not empty), `To`, `Cc` and `Bcc` (each only when its list is not empty), `Subject`, `Date`, `Message-ID` (a new one per call, `<UUID@domain-of-the-account>`), `MIME-Version: 1.0`, `Content-Type: text/plain; charset=utf-8` and `Content-Transfer-Encoding`, each once; a body that is the given text with every line ending made CRLF and one CRLF at the end. Non-ASCII header text SHALL be RFC 2047 encoded words, and no line SHALL pass 998 octets. The body SHALL be sent `7bit` when it is ASCII and no line passes 998 octets, and `base64` in lines of 76 otherwise. The message SHALL NOT carry `X-Uniform-Type-Identifier` or any `X-Apple-` field, and SHALL NOT be multipart. The tool SHALL append it to the mailbox the server reports with `\Drafts` (refusing as `send_draft` does when there is none or more than one) with the flags `\Draft` and `\Seen`, SHALL NOT run AppleScript, SHALL NOT require Mail to be running, and SHALL NOT modify the local Envelope Index or any `.emlx` file.

#### Scenario: A display-name recipient

- **WHEN** `append_draft` is called with `to: ["Name <a@example.com>"]`
- **THEN** the call fails saying the recipient is not a bare address, and no connection is opened

#### Scenario: A line break in the subject

- **WHEN** `append_draft` is called with a `subject` that holds CR LF
- **THEN** the call fails naming `subject`, and no connection is opened

#### Scenario: The message is not in Mail's draft layout

- **WHEN** `append_draft` builds a message with a Chinese body
- **THEN** the message is one `text/plain; charset=utf-8` part in `base64`, every line ends in CRLF, and it carries no `X-Uniform-Type-Identifier` or `X-Apple-` field

### Requirement: An append has one of three outcomes and is never repeated

The result of `append_draft` SHALL be exactly one of:

- `appended`: the server completed the APPEND command. The result carries the UID and UIDVALIDITY when the server reports them.
- `not_appended`: the server refused the command with a tagged NO or BAD reply; or the message was larger than the limit the server announced and nothing was sent; or the call stopped before the APPEND command was sent, because opening the connection, logging in or finding the drafts mailbox failed. In the last case the result carries no mailbox.
- `unknown`: every other case, including a closed connection, a timeout and an error the tool does not recognise.

Argument, configuration and credential refusals, which happen before any connection, SHALL remain errors and SHALL NOT be results. After an `unknown` APPEND the tool SHALL attempt one search of the drafts mailbox for the message's Message-ID and compare each hit in full, so that a hit whose Message-ID only contains this one does not count. Exactly one hit SHALL make the outcome `appended` with that hit's UID; more than one SHALL make it `appended` without a UID. A search that fails SHALL leave the outcome `unknown`, and the result SHALL say that the search could not be made; a search that finds nothing SHALL leave it `unknown`, and the result SHALL say that not seeing the draft is not evidence that it was not stored. The tool SHALL NOT append the message a second time in the same call. The result of every outcome SHALL carry the Message-ID and the mailbox (null when it was not found), and SHALL say that the tool does not change the local mail index; an `appended` result SHALL also say that calls are not de-duplicated, and an `unknown` result SHALL say that the tool is not retrying and that calling again creates a second draft if the first was stored. One direct-transport call SHALL run at a time: `append_draft` SHALL hold the lock `send_draft` holds, from opening its connection to closing it, and a second call SHALL be refused without waiting. Error texts and server replies in results SHALL have the password removed as for `send_draft`.

#### Scenario: No reply arrives and the search finds nothing

- **WHEN** the APPEND times out before the tagged reply, and a search afterwards finds no message with the Message-ID
- **THEN** the result is `unknown`, the tool does not append again, and the result says that not seeing the draft is not evidence that it was not stored

#### Scenario: The login fails

- **WHEN** opening the IMAP connection or logging in fails
- **THEN** the result is `not_appended` with no mailbox, and nothing was sent to the server

##### Example: append outcomes

| What the server or SwiftMail reports | Search afterwards | Outcome | UID in the result |
| --- | --- | --- | --- |
| tagged OK with `APPENDUID` | not made | `appended` | yes |
| tagged OK without `APPENDUID` | not made | `appended` | no |
| tagged NO (for example over quota) | not made | `not_appended` | no |
| message over the announced size limit | not made | `not_appended` | no |
| timeout, no reply | one hit | `appended` | yes |
| timeout, no reply | two hits | `appended` | no |
| connection closed, no reply | the search fails | `unknown` | no |
| timeout, no reply | no hit | `unknown` | no |

### Requirement: append_draft states that it has not been run against a real server

Until the tool has been run against a real mail server and the result recorded on the tracking issue, the `append_draft` tool description SHALL say that it has not been run against a real server, SHALL name the tracking issue, and SHALL say that a second call creates a second draft.

#### Scenario: The description carries the caveat

- **WHEN** the tool list is read
- **THEN** the `append_draft` description says it has not been run against a real server, names issue #744, and says a second call creates a second draft


## MODIFIED Requirements

### Requirement: send_draft sends one existing draft and cannot write content

The `send_draft` tool SHALL accept exactly these arguments: `account_name`, `account_id`, `draft_id`, `subject_match` and `message_id`. A call that carries any other argument, including `body`, `to`, `cc`, `bcc` and `attachments`, SHALL be refused by name before any connection is opened. Exactly one of `draft_id`, `subject_match` and `message_id` SHALL be given. The tool SHALL select the draft in the account's drafts mailbox on the server: with `subject_match`, the drafts whose subject equals it exactly; with `draft_id`, the drafts whose Message-ID equals the Message-ID of that local message row; with `message_id`, the drafts whose Message-ID equals it, without reading the local store. A `message_id` that holds any character outside printable ASCII without space, or has no `@`, SHALL be refused by name before any connection is opened. With `draft_id` and `message_id` both Message-IDs are put in the form `<local@domain>` before they are compared, and the server is searched for the Message-ID without its angle brackets so that a header written without them is found; each hit is then compared in full, so a hit whose Message-ID only contains the one searched for does not count. An argument whose value is JSON null SHALL be refused by name. When both `account_id` and `account_name` are given and name different configured accounts, the call SHALL be refused. An empty `subject_match` selects the drafts whose subject is empty. Subjects and Message-IDs SHALL be compared scalar by scalar, not by Unicode canonical equivalence. A search hit whose envelope the server does not return SHALL make the call fail, since the match can then not be shown to be unique. The UID of the selected draft SHALL be used only while the drafts mailbox reports the UIDVALIDITY it had when the draft was found; otherwise the call SHALL stop. The draft fetched SHALL be refused unless it still has the Message-ID (and, with `subject_match`, the subject) of the search hit. The drafts mailbox SHALL be the one the server reports with the special-use attribute `\Drafts`; when the server reports none, or more than one, the call SHALL be refused. When the selection matches no draft or more than one, the call SHALL be refused and nothing SHALL be submitted. The tool SHALL NOT run AppleScript, SHALL NOT require Mail to be running, and SHALL NOT modify the local Envelope Index or any `.emlx` file.

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
