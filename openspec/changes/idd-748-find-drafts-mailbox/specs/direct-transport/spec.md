## ADDED Requirements

### Requirement: The drafts and sent mailboxes are found in a fixed order

`send_draft` and `append_draft` SHALL find the drafts mailbox from the attribute `\Drafts` and the key `drafts_mailbox`, and `send_draft` SHALL find the sent mailbox from the attribute `\Sent` and the key `sent_mailbox`, by these rules, tried in this order; the first rule that applies decides, and no other rule SHALL be used:

1. The server's mailbox list (`LIST` without return options) marks exactly one mailbox with the attribute: that mailbox, unless the server also marks it `\Noselect`, in which case the call SHALL be refused without trying the later rules.
2. That list marks more than one: the call SHALL be refused.
3. That list marks none and the server's capabilities, fetched after login and only at this point (so that a failure to fetch them cannot override rules 1 and 2), hold `SPECIAL-USE`: the server SHALL be asked once more with `LIST` and the return option `SPECIAL-USE`. Exactly one mailbox marked: that mailbox, refused as in rule 1 when it is marked `\Noselect`. More than one: the call SHALL be refused. None: the next rule applies. A server whose capabilities do not hold `SPECIAL-USE` SHALL NOT be asked this way. When the capabilities cannot be read, or the server advertises `SPECIAL-USE` and the request for its special-use mailboxes fails, the call SHALL be refused without trying rule 4, since it cannot then be known whether the server would mark a mailbox when asked; the refusal SHALL say how many mailboxes were listed, whether `SPECIAL-USE` is advertised when that is known, and which of the two steps failed, in fixed text that does not include the error the server or library returned.
4. The account's entry in `direct-transport.json` holds the key: the mailbox the server lists under that name, when the server's mailbox list holds exactly one mailbox whose name equals it scalar by scalar (not by Unicode canonical equivalence) and the server does not mark that mailbox `\Noselect`; otherwise the call SHALL be refused, saying whether no mailbox, more than one, or one that cannot be selected was found. The name used afterwards SHALL be the one the server listed.
5. Otherwise the call SHALL be refused.

A mailbox SHALL NOT be chosen because of what it is called, except by rule 4, where the name is the one the maintainer wrote. A refusal under rules 4 and 5 SHALL say how many mailboxes the server listed, whether its capabilities hold `SPECIAL-USE`, and which key to add or correct; a refusal under rules 2 and 3 SHALL say how many mailboxes the server marked and listed, and under rule 2 that `SPECIAL-USE` was not checked. No refusal or note built by these rules SHALL contain a mailbox name or the server's capability list; an error the server or the IMAP library returns while listing passes through the same redaction as every other server text. When a mailbox is found and the call ends in a result (not an error), the result SHALL carry a note saying which rule found it; when rule 1 or 3 found it and the key does not equal the name the server gave scalar by scalar, the note SHALL say that the key does not exactly match and that the server's mark was used. A new submission SHALL record the drafts mailbox it was submitted from. A pending stage SHALL be completed, and a missing draft SHALL be taken as already removed, only while the drafts mailbox found is the recorded one, equal scalar by scalar; otherwise the call SHALL be refused and nothing stored or removed, since a sent copy has the same Message-ID and bytes as the draft. An entry that holds no drafts mailbox (written before this requirement) SHALL NOT be resumed and SHALL NOT have its removal inferred: its origin cannot be shown. A refusal when the sent mailbox is looked for SHALL NOT change a `submitted` outcome: the sent copy stage SHALL be pending, as for any failure of that stage. When the sent mailbox found may be the drafts mailbox (the two names, both as the server gave them, are equal scalar by scalar, canonically equivalent, or equal ignoring ASCII letter case: IMAP treats `INBOX` so and some servers treat every name so, and matching too much only leaves the stages pending), the sent copy stage SHALL fail in the same way before any search of the sent mailbox, and the draft SHALL NOT be removed: the draft would otherwise count as its own sent copy and could be expunged as the only stored copy.

#### Scenario: A server whose plain list marks no mailbox

- **WHEN** the server's mailbox list marks no mailbox `\Drafts`, its capabilities do not hold `SPECIAL-USE`, and the entry holds `drafts_mailbox: "Drafts"` and the server lists a mailbox `Drafts`
- **THEN** that mailbox is used, the server is not asked for its special-use mailboxes, and the result's notes say the drafts mailbox came from `drafts_mailbox`

#### Scenario: Nothing to go by

- **WHEN** the server marks no mailbox `\Drafts` by either list and the entry holds no `drafts_mailbox`
- **THEN** `send_draft` fails and `append_draft` reports `not_appended`, both saying how many mailboxes were listed, whether `SPECIAL-USE` is advertised, and to add `drafts_mailbox`; nothing is submitted or appended

#### Scenario: A name the server does not list

- **WHEN** the server marks no mailbox `\Drafts` and `drafts_mailbox` is `brouillons` while the server lists `Brouillons`
- **THEN** the call is refused saying the name must match exactly, and the refusal contains neither `brouillons` nor `Brouillons`

#### Scenario: The drafts mailbox changed before a pending removal

- **WHEN** a draft was submitted from `Drafts`, its sent copy is done and its removal pending, and `drafts_mailbox` now names the sent mailbox, or the entry records no drafts mailbox
- **THEN** a later `send_draft` for that draft is refused, nothing is removed, and the removal stays pending

#### Scenario: The sent mailbox is the drafts mailbox

- **WHEN** a draft is submitted with `sent_copy: append` and the sent mailbox found is the drafts mailbox, also when one is given as `Sent` and the other as `sent`
- **THEN** the result is `submitted` with the sent copy pending and the draft's removal pending, the sent mailbox is not searched, and the draft stays in the drafts mailbox

##### Example: which mailbox is used

| Plain list marks | SPECIAL-USE advertised | Asked again marks | Key | Result |
| --- | --- | --- | --- | --- |
| one | any | not asked | any | the marked one (refused if `\Noselect`) |
| two | any | not asked | any | refused |
| none | yes | one | any | the marked one (refused if `\Noselect`) |
| none | could not be read | not asked | any | refused |
| none | yes | request failed | any | refused |
| none | yes | two | any | refused |
| none | yes | none | a listed name | the named one |
| none | no | not asked | a listed name | the named one |
| none | any | none or not asked | a name not listed, listed twice, or `\Noselect` | refused |
| none | any | none or not asked | absent | refused |

## MODIFIED Requirements

### Requirement: Direct transport is available only for accounts configured for it

The server SHALL read the direct-transport configuration from the file `direct-transport.json` in its state directory. The file SHALL hold, per account, exactly these fields: `account_id` (the Mail account UUID), `address` (the account's own address, also the login name), `smtp` (`host`, `port`), `imap` (`host`, `port`), `sent_copy` (`append` or `provider`) and `allowed_from` (a list of further addresses the account may send as, possibly empty). An entry MAY also hold `drafts_mailbox` and `sent_mailbox`, each the exact name of a mailbox on the account's IMAP server; when present, each SHALL be a string that is not empty, holds no control character and is at most 255 bytes of UTF-8, and SHALL be kept as written, without trimming or case folding. These two names are used only as the Requirement "The drafts and sent mailboxes are found in a fixed order" states. The file SHALL NOT hold a password. When the file does not exist, or holds no entry for the account a call names, the call SHALL be refused as not configured. An `account_id` that is not a UUID, a `host` that holds anything but ASCII letters, digits, hyphens and dots, an `address` or `allowed_from` entry that is not one `@` between non-empty parts of printable ASCII without `,;:<>()[]"\` or space, and two entries with the same `account_id` or the same `address` (compared without regard to ASCII letter case) SHALL count as values outside the ones listed. When the file exists and cannot be parsed, or an entry lacks a field or holds a value outside the ones listed, every direct-transport call SHALL be refused with a message that names the problem; a file that cannot be read SHALL NOT be treated as an absent one. A refused call SHALL NOT fall back to any path that drives Mail.

#### Scenario: No configuration

- **WHEN** `send_draft` is called and `direct-transport.json` does not exist
- **THEN** the call fails saying direct transport is not configured for the account, no connection is opened, and no Mail script runs

#### Scenario: A configuration the server cannot read

- **WHEN** `send_draft` is called and `direct-transport.json` exists and is not valid JSON, or an entry has `sent_copy: "maybe"`
- **THEN** the call fails naming the file and the problem, and no connection is opened

### Requirement: send_draft sends one existing draft and cannot write content

The `send_draft` tool SHALL accept exactly these arguments: `account_name`, `account_id`, `draft_id`, `subject_match` and `message_id`. A call that carries any other argument, including `body`, `to`, `cc`, `bcc` and `attachments`, SHALL be refused by name before any connection is opened. Exactly one of `draft_id`, `subject_match` and `message_id` SHALL be given. The tool SHALL select the draft in the account's drafts mailbox on the server: with `subject_match`, the drafts whose subject equals it exactly; with `draft_id`, the drafts whose Message-ID equals the Message-ID of that local message row; with `message_id`, the drafts whose Message-ID equals it, without reading the local store. A `message_id` longer than 998 octets, or that holds any character outside printable ASCII without space, or has no `@`, SHALL be refused by name before any connection is opened. With `draft_id` and `message_id` both Message-IDs are put in the form `<local@domain>` before they are compared, and the server is searched for the Message-ID without its angle brackets so that a header written without them is found; each hit is then compared in full, so a hit whose Message-ID only contains the one searched for does not count. An argument whose value is JSON null SHALL be refused by name. When both `account_id` and `account_name` are given and name different configured accounts, the call SHALL be refused. An empty `subject_match` selects the drafts whose subject is empty. Subjects and Message-IDs SHALL be compared scalar by scalar, not by Unicode canonical equivalence. A search hit whose envelope the server does not return SHALL make the call fail, since the match can then not be shown to be unique. The UID of the selected draft SHALL be used only while the drafts mailbox reports the UIDVALIDITY it had when the draft was found; otherwise the call SHALL stop. The draft fetched SHALL be refused unless it still has the Message-ID (and, with `subject_match`, the subject) of the search hit. The drafts mailbox SHALL be found as the Requirement "The drafts and sent mailboxes are found in a fixed order" states; when it is not found, the call SHALL be refused and nothing SHALL be submitted. When the selection matches no draft or more than one, the call SHALL be refused and nothing SHALL be submitted. The tool SHALL NOT run AppleScript, SHALL NOT require Mail to be running, and SHALL NOT modify the local Envelope Index or any `.emlx` file.

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

### Requirement: The sent copy and the draft's removal are separate stages after submission

After a `submitted` outcome the tool SHALL, in this order: when `sent_copy` is `append`, append the draft's bytes as fetched, `Bcc` fields included, to the sent mailbox, found as the Requirement "The drafts and sent mailboxes are found in a fixed order" states, with the `\Seen` flag; then remove the draft from the drafts mailbox by marking that one message deleted and expunging that one message. When `sent_copy` is `provider` the first stage SHALL be reported as skipped. The removal SHALL NOT expunge any other message; when the server offers no way to expunge one message by its UID, the removal SHALL be reported as pending and not attempted. A failure of either stage SHALL NOT change the `submitted` outcome: the result SHALL name the stage as pending, and the entry SHALL record it. When `send_draft` is called for a draft whose entry is `submitted` with a stage pending, the tool SHALL perform only the pending stages and SHALL NOT submit the message again, and SHALL do so only when the call names the account that submitted the draft, with the same login and IMAP server, and the draft fetched has the bytes that were submitted (the entry records their SHA-256); otherwise the call SHALL be refused and nothing stored or removed. Before storing the sent copy the tool SHALL look for a message whose Message-ID equals the draft's in the sent mailbox (a search hit alone is not enough: IMAP header search matches substrings) and, when there is one, SHALL record the stage as done without storing a second copy. When a call with `draft_id` finds no draft and the entry for its Message-ID is `submitted` with only the removal pending, the removal SHALL be recorded as done, but only when the entry records the drafts mailbox it was submitted from and that is the drafts mailbox found now (Requirement "The drafts and sent mailboxes are found in a fixed order"). The draft SHALL NOT be removed while the record still shows the sent copy as pending. The entry SHALL keep the time of submission apart from the time of its last change, and its write SHALL be durable (the file and its directory synchronised) before the SMTP transaction starts. After a `submitted` outcome the result SHALL state each stage as done, pending or skipped; a stage that was not attempted because an earlier one failed is pending. After a `not_sent` or `unknown` outcome the result SHALL state both stages as not attempted. Every result SHALL say that the local mail index is not changed by this tool and follows when Mail next synchronises.

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
