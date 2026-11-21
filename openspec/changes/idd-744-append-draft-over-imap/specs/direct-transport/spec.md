## ADDED Requirements

### Requirement: append_draft creates one new draft on the server and builds it itself

The `append_draft` tool SHALL accept exactly these arguments: `account_name`, `account_id`, `to`, `cc`, `bcc`, `subject`, `body` and `from_name`. A call that carries any other argument, including `attachments`, `format` and `from_address`, SHALL be refused by name before any connection is opened. `to`, `cc` and `bcc` SHALL be lists of strings, absent meaning empty; `subject`, `body`, `from_name`, `account_name` and `account_id` SHALL be strings; a value of another type, JSON null included, SHALL be refused by name. `subject` and `body` SHALL be given, and `subject` SHALL NOT be empty. There SHALL be at least one recipient in `to`, `cc` and `bcc` together. Every recipient SHALL be a bare address: printable ASCII, exactly one `@` between non-empty parts, none of `,;:<>()[]"\` or space, at most 254 octets; anything else, a display name included, SHALL be refused. `subject` and `from_name` SHALL NOT hold a control character (below U+0020, or U+007F), and `body` SHALL NOT hold NUL. These checks SHALL happen before the configuration is read and before any connection is opened. The account SHALL be chosen and refused as `send_draft` chooses and refuses it, and the credential and the connection SHALL follow the requirements that apply to `send_draft`; the tool SHALL NOT connect to the SMTP server.

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
- `not_appended`: the server refused the command with a tagged NO or BAD reply, or the message was larger than the limit the server announced and nothing was sent.
- `unknown`: every other case, including a closed connection, a timeout and an error the tool does not recognise.

After an `unknown` APPEND the tool SHALL search the drafts mailbox once for the message's Message-ID and compare each hit in full. Exactly one hit SHALL make the outcome `appended` with that hit's UID; more than one SHALL make it `appended` without a UID; a failed search or no hit SHALL leave it `unknown`, and the result SHALL say that not seeing the draft is not evidence that it was not stored. The tool SHALL NOT append the message a second time in the same call. The result of every outcome SHALL carry the Message-ID and the mailbox; an `unknown` result SHALL say that the tool is not retrying and that a second call creates a second draft if the first was stored. One direct-transport call SHALL run at a time: `append_draft` SHALL hold the lock `send_draft` holds, from opening its connection to closing it, and a second call SHALL be refused without waiting. Error texts and server replies in results SHALL have the password removed as for `send_draft`.

#### Scenario: The connection closes before the server's reply

- **WHEN** the IMAP connection closes after the APPEND was sent and before the tagged reply, and a search afterwards finds no message with the Message-ID
- **THEN** the result is `unknown`, the tool does not append again, and the result says that not seeing the draft is not evidence that it was not stored

##### Example: append outcomes

| What the server or SwiftMail reports | Search afterwards | Outcome | UID in the result |
| --- | --- | --- | --- |
| tagged OK with `APPENDUID` | not made | `appended` | yes |
| tagged OK without `APPENDUID` | not made | `appended` | no |
| tagged NO (for example over quota) | not made | `not_appended` | no |
| message over the announced size limit | not made | `not_appended` | no |
| connection closed, no reply | one hit | `appended` | yes |
| connection closed, no reply | two hits | `appended` | no |
| timeout | no hit, or the search fails | `unknown` | no |

### Requirement: send_draft chooses a draft by its Message-ID

`send_draft` SHALL accept `message_id` as a third way to choose the draft. Exactly one of `draft_id`, `subject_match` and `message_id` SHALL be given. A `message_id` that holds any character outside printable ASCII without space, or has no `@`, SHALL be refused by name before any connection is opened. It SHALL be put in the form `<local@domain>`, and the drafts SHALL be selected as with `draft_id`: the server is searched for it without its angle brackets, and each hit is compared in full. The local store SHALL NOT be read. Every other rule of the requirement on `send_draft`'s selection applies unchanged.

#### Scenario: A draft made by append_draft is sent with Mail closed

- **WHEN** `send_draft` is called with the `message_id` an `append_draft` call returned, while Mail is not running
- **THEN** that draft is selected on the server without reading the local store, and it is submitted as any selected draft is

### Requirement: append_draft states that it has not been run against a real server

Until the tool has been run against a real mail server and the result recorded on the tracking issue, the `append_draft` tool description SHALL say that it has not been run against a real server, SHALL name the tracking issue, and SHALL say that a second call creates a second draft.

#### Scenario: The description carries the caveat

- **WHEN** the tool list is read
- **THEN** the `append_draft` description says it has not been run against a real server, names issue #744, and says a second call creates a second draft
