## ADDED Requirements

### Requirement: Direct transport is available only for accounts configured for it

The server SHALL read the direct-transport configuration from the file `direct-transport.json` in its state directory. The file SHALL hold, per account, exactly these fields: `account_id` (the Mail account UUID), `address` (the account's own address, also the login name), `smtp` (`host`, `port`), `imap` (`host`, `port`), `sent_copy` (`append` or `provider`) and `allowed_from` (a list of further addresses the account may send as, possibly empty). The file SHALL NOT hold a password. When the file does not exist, or holds no entry for the account a call names, the call SHALL be refused as not configured. When the file exists and cannot be parsed, or an entry lacks a field or holds a value outside the ones listed, every direct-transport call SHALL be refused with a message that names the problem; a file that cannot be read SHALL NOT be treated as an absent one. A refused call SHALL NOT fall back to any path that drives Mail.

#### Scenario: No configuration

- **WHEN** `send_draft` is called and `direct-transport.json` does not exist
- **THEN** the call fails saying direct transport is not configured for the account, no connection is opened, and no Mail script runs

#### Scenario: A configuration the server cannot read

- **WHEN** `send_draft` is called and `direct-transport.json` exists and is not valid JSON, or an entry has `sent_copy: "maybe"`
- **THEN** the call fails naming the file and the problem, and no connection is opened

### Requirement: The credential comes only from the server's own keychain item

The password for a configured account SHALL be read, at call time, from a generic-password keychain item whose service is `che-apple-mail-mcp.direct-transport` and whose account is the configured `address`. The server SHALL NOT read keychain items that belong to Mail or to any other application. The password SHALL NOT appear in any tool argument, tool result, stderr line, log, or file the server writes. The binary SHALL provide a command-line mode, `--direct-transport-set-credential <address>`, that reads the password from standard input and creates or replaces that item; no MCP tool SHALL create, change or reveal it. When the item does not exist, a direct-transport call SHALL be refused with a message that names that command-line mode, before any connection is opened.

#### Scenario: No stored credential

- **WHEN** `send_draft` is called for a configured account whose keychain item does not exist
- **THEN** the call fails naming `--direct-transport-set-credential`, and no connection is opened

### Requirement: Connections are encrypted before the password is sent

Every connection to a configured server SHALL be protected by TLS before the password is sent: implicit TLS when the configured port is 465 or 993, and STARTTLS on any other port, required rather than opportunistic, so that a server that does not offer STARTTLS fails the connection. The server's certificate SHALL be verified against the trusted roots and the configured host name, and the connection SHALL NOT negotiate a TLS version older than 1.2. No plaintext transport SHALL be used. A connection that fails any of these SHALL be refused before any draft is read, and nothing SHALL be submitted.

#### Scenario: A server that does not offer STARTTLS

- **WHEN** the configured SMTP port is 587 and the server does not offer STARTTLS
- **THEN** the call fails before logging in, the password is not sent, and nothing is submitted

### Requirement: send_draft sends one existing draft and cannot write content

The `send_draft` tool SHALL accept exactly these arguments: `account_name`, `account_id`, `draft_id` and `subject_match`. A call that carries any other argument, including `body`, `to`, `cc`, `bcc` and `attachments`, SHALL be refused by name before any connection is opened. Exactly one of `draft_id` and `subject_match` SHALL be given. The tool SHALL select the draft in the account's drafts mailbox on the server: with `subject_match`, the drafts whose subject equals it exactly; with `draft_id`, the drafts whose Message-ID equals the Message-ID of that local message row. The drafts mailbox SHALL be the one the server reports with the special-use attribute `\Drafts`; when the server reports none, or more than one, the call SHALL be refused. When the selection matches no draft or more than one, the call SHALL be refused and nothing SHALL be submitted. The tool SHALL NOT run AppleScript, SHALL NOT require Mail to be running, and SHALL NOT modify the local Envelope Index or any `.emlx` file.

#### Scenario: An argument that could write content

- **WHEN** `send_draft` is called with `draft_id` and `body`
- **THEN** the call fails naming `body`, and no connection is opened

#### Scenario: Two drafts share the subject

- **WHEN** `send_draft` is called with a `subject_match` that equals the subject of two drafts on the server
- **THEN** the call fails saying two drafts matched, and nothing is submitted

#### Scenario: The draft is not on the server

- **WHEN** `send_draft` is called with a `draft_id` whose message row exists locally and no draft on the server carries its Message-ID
- **THEN** the call fails saying the draft is not on the server, and nothing is submitted

### Requirement: A draft is checked before it is submitted

Before submission the tool SHALL check the draft it fetched from the server, in this order, and SHALL refuse the call at the first check that fails, submitting nothing and leaving the draft in place:

1. The draft has a Message-ID.
2. The record of sent drafts holds no entry for that Message-ID in the state `attempting`, `unknown` or `submitted` with nothing pending. (An entry in the state `submitted` with a stage pending is completed instead; see the requirement on stages after submission.)
3. The From field names exactly one address, and that address equals the configured `address` or one of `allowed_from`, compared without regard to ASCII letter case.
4. To, Cc and Bcc together name at least one address, and none of them holds text that is not an address.
5. Every line of the header section, the blank line that ends it included, ends in CRLF; the header section holds no `Resent-Bcc` field; and every line of it can be told to be, or not to be, part of a `Bcc` field.

#### Scenario: The sender is not the account's

- **WHEN** the selected draft's From address is neither the configured `address` nor in `allowed_from`
- **THEN** the call fails naming the From address, nothing is submitted, and the draft stays on the server

#### Scenario: The draft was already sent

- **WHEN** the record of sent drafts holds the draft's Message-ID in the state `submitted` with nothing pending
- **THEN** the call fails saying the draft was already submitted and when, and nothing is submitted

### Requirement: The submitted message is the draft without its Bcc fields

The envelope sender SHALL be the draft's From address. The envelope recipients SHALL be every address in the draft's To, Cc and Bcc fields. The message content handed to the SMTP server SHALL be the bytes of the draft as fetched from the server with every `Bcc` header field removed, folded continuation lines included, and no other byte changed.

#### Scenario: A draft with a Bcc recipient

- **WHEN** a draft with one To address and one Bcc address is submitted
- **THEN** both addresses are envelope recipients, and the submitted content holds no `Bcc` field and is otherwise byte for byte the draft

### Requirement: A submission has one of three outcomes

Before the SMTP transaction is started the tool SHALL write an entry for the draft's Message-ID in the record of sent drafts with the state `attempting`. The result of the submission SHALL be exactly one of:

- `submitted`: the SMTP server gave a final 2xx reply to the message. The entry becomes `submitted` and records the reply and the time.
- `not_sent`: one of these, and no other: the failure happened before the SMTP mail transaction started; or the transport reports that the server provably did not receive the complete message; or the server explicitly rejected the message with a final 4xx or 5xx reply. The entry is removed, the draft stays on the server, and the result carries the server's reply when there is one.
- `unknown`: every other case, including a timeout or a lost connection after the transaction started. The entry becomes `unknown`. The result SHALL say that the state is unknown and that the tool is not retrying, and SHALL NOT say that the message was or was not sent.

An entry found in the state `attempting` at the start of a call SHALL be read as `unknown`. An `unknown` entry SHALL be removable only by the command-line mode `--direct-transport-forget <message-id>`; no MCP tool SHALL remove it.

#### Scenario: The connection is lost after the content was handed over

- **WHEN** the SMTP connection is lost after the message content was handed to the transport and before a final reply arrived
- **THEN** the result is `unknown`, the entry stays as `unknown`, nothing is retried, and a later `send_draft` for the same draft is refused

##### Example: submission outcomes

| What the transport reports | Outcome | Entry afterwards | Draft on the server |
| --- | --- | --- | --- |
| final `250` reply | `submitted` | `submitted` | removed by the next stage |
| authentication failed, before the transaction | `not_sent` | none | kept |
| a recipient rejected with `550`, transaction aborted | `not_sent` | none | kept |
| final `552` reply after the content | `not_sent` | none | kept |
| final `451` reply after the content | `not_sent` | none | kept |
| connection lost after the content, no reply | `unknown` | `unknown` | kept |
| timeout waiting for the final reply | `unknown` | `unknown` | kept |
| an error the tool does not recognise | `unknown` | `unknown` | kept |

### Requirement: The sent copy and the draft's removal are separate stages after submission

After a `submitted` outcome the tool SHALL, in this order: when `sent_copy` is `append`, append the draft's bytes as fetched, `Bcc` fields included, to the mailbox the server reports with the special-use attribute `\Sent`, with the `\Seen` flag; then remove the draft from the drafts mailbox by marking that one message deleted and expunging that one message. When `sent_copy` is `provider` the first stage SHALL be reported as skipped. The removal SHALL NOT expunge any other message; when the server offers no way to expunge one message by its UID, the removal SHALL be reported as pending and not attempted. A failure of either stage SHALL NOT change the `submitted` outcome: the result SHALL name the stage as pending, and the entry SHALL record it. When `send_draft` is called for a draft whose entry is `submitted` with a stage pending, the tool SHALL perform only the pending stages and SHALL NOT submit the message again. After a `submitted` outcome the result SHALL state each stage as done, pending or skipped; a stage that was not attempted because an earlier one failed is pending. After a `not_sent` or `unknown` outcome the result SHALL state both stages as not attempted. Every result SHALL say that the local mail index is not changed by this tool and follows when Mail next synchronises.

#### Scenario: The sent copy cannot be stored

- **WHEN** the message was submitted and the append to the sent mailbox fails
- **THEN** the result is `submitted` with the sent copy pending and the draft's removal pending (not attempted), and a later `send_draft` for the same draft stores the copy and removes the draft without submitting again

##### Example: stages after submission

| sent_copy | Append | Removal | Result |
| --- | --- | --- | --- |
| `append` | succeeds | succeeds | `submitted`; sent copy done; draft removed |
| `append` | fails | not attempted | `submitted`; sent copy pending; draft removal pending |
| `append` | succeeds | fails | `submitted`; sent copy done; draft removal pending |
| `provider` | skipped | succeeds | `submitted`; sent copy skipped; draft removed |
| `append`, server without expunge by UID | succeeds | not attempted | `submitted`; sent copy done; draft removal pending |

### Requirement: send_draft states that it has not been run against a real server

Until the tool has been run against a real mail server and the result recorded on the tracking issue, the `send_draft` tool description SHALL say that it has not been run against a real server and SHALL name the tracking issue.

#### Scenario: The description carries the caveat

- **WHEN** the tool list is read
- **THEN** the `send_draft` description says it has not been run against a real server and names issue #742
