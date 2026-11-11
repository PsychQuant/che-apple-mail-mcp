## MODIFIED Requirements

### Requirement: Direct-write draft path

When the environment variable `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT` equals `1`, `create_draft` SHALL first attempt to create the draft by writing it directly into Mail's local store (the Envelope Index and an `.emlx` file) and then asking Mail to upload it. When the variable is unset or has any other value, `create_draft` SHALL NOT attempt the direct write and its result SHALL carry no note about it.

Before writing anything, the system SHALL check eligibility. The call is ineligible, and SHALL take the GUI path, when any of the following holds. This list is closed; no other condition makes a call ineligible at this stage:

1. `format` is not `plain`.
2. `attachments` is non-empty.
3. `cc` or `bcc` is non-empty.
4. `to` is empty.
5. A `to` entry carries a display name.
6. A `to` entry is not a plain addr-spec, or is longer than 254 octets, the SMTP path limit (RFC 5321 section 4.5.3.1.3). Header folding cannot split an address, so the length is bounded here.
7. `subject` is empty.
8. `from_address` is absent or empty.
9. `from_address` is not a bare addr-spec.
10. `signature` has mode `named`. The direct write inserts no signature yet (#587), so a named one is applied on the GUI path. Mode `none` is what the direct write produces; mode `mail_default` is checked by gate (3).

After eligibility passes and before writing, the system SHALL also require all of the following, checked in this order, and SHALL take the GUI path at the first that fails: (1) Mail's version is 16.x and the macOS major version is 27; (2) `from_address` maps to exactly one Mail account; (3) when `signature` is `mail_default`, Mail's `AccountsMap.plist` lists no signature for that account (an unreadable list fails this gate), because a signature Mail would insert is not written directly; (4) the Envelope Index is readable; (5) the account's Drafts mailbox is identified and matched to a mailbox path in the index; (6) the store opens for writing; (7) the store's `messages` columns equal the verified set and every other table it writes has its required columns; (8) that Drafts path corresponds to exactly one mailbox row and its URL is an IMAP URL; (9) a sender address row already exists for `from_address` in that account. A draft created by the direct write SHALL carry a disclosure that no signature was inserted.

The write SHALL happen inside a single `BEGIN IMMEDIATE` transaction, with the `.emlx` file renamed into place inside that transaction. A failure during the write SHALL roll the transaction back and remove the file, and the call SHALL take the GUI path. The write SHALL record, as the directories it created, only the directory levels its own creation call made; a level that already existed, or that another process created first, SHALL NOT be recorded. When the write fails, and when a committed write is reversed, the system SHALL remove the recorded directories after the `.emlx` file, deepest first, removing a directory only while it is empty and without removing anything inside it. A recorded directory that no longer exists SHALL be skipped and the removal SHALL go on to the next level up; the removal SHALL stop at the first recorded directory that still exists and cannot be removed. When a removal fails for a reason other than the directory not being empty or no longer existing, the system SHALL write a line naming the directory and the reason to stderr. Removing those directories SHALL NOT change the error a failed write reports, and a directory that cannot be removed SHALL NOT make reversing the write fail.

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
- **AND** the system SHALL remove every directory the write created for the `.emlx` file that is still empty
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

#### Scenario: A failed write removes the directories it created and keeps the rest

- **WHEN** the write fails after the `.emlx` file was placed, or while placing it after its directories were created
- **THEN** the system SHALL remove every directory level the write created for the file
- **AND** the system SHALL NOT remove a directory level that existed before the write
- **AND** the error the call reports SHALL be the error of the failed step

##### Example: a new hash block is removed after a later step fails
- **GIVEN** a Drafts store whose `Data` directory exists, and the next message row id 20000, so the file goes to `Data/0/2/Messages/20000.emlx`
- **WHEN** the write places the file and then fails at a later step with the error `no WriteTransactionGeneration`
- **THEN** `Data/0`, `Data/0/2` and `Data/0/2/Messages` no longer exist, `Data` still exists, and the write reports `no WriteTransactionGeneration`

##### Example: a failure while placing the file removes the new directories
- **GIVEN** the same store and row id
- **WHEN** placing the file fails after `Data/0/2/Messages` was created and before the file was written
- **THEN** `Data/0` no longer exists and `Data` still exists

#### Scenario: A directory that is not empty is kept

- **WHEN** the write fails, or a committed write is reversed, and a directory the write created now holds a file the write did not place
- **THEN** the system SHALL remove the `.emlx` file it placed
- **AND** the system SHALL keep that directory and every directory above it, together with the other file
- **AND** reversing a committed write SHALL NOT report a failure because of that directory

##### Example: another file in the new Messages directory survives a failed write
- **GIVEN** the write created `Data/0/2/Messages` and placed `20000.emlx` in it, and another file `20001.emlx` appeared in that directory
- **WHEN** the write fails at a later step
- **THEN** `20000.emlx` is removed, and `20001.emlx`, `Data/0/2/Messages`, `Data/0/2` and `Data/0` remain

##### Example: another file in the new Messages directory survives a reversal
- **GIVEN** a committed write that created `Data/0/2/Messages`, and another file `20001.emlx` that appeared in that directory
- **WHEN** the write is reversed
- **THEN** the reversal succeeds, `20000.emlx` is removed, and `20001.emlx` and its directories remain

#### Scenario: Reversing a committed write removes the directories it created

- **WHEN** a committed write that created directories for its `.emlx` file is reversed
- **THEN** the system SHALL remove those directories once the file is removed
- **AND** the system SHALL NOT remove a directory level that existed before the write

##### Example: reversal removes only the levels the write created
- **GIVEN** a store where `Data/0` already exists, and a committed write that created `Data/0/2` and `Data/0/2/Messages` for `20000.emlx`
- **WHEN** the write is reversed
- **THEN** `Data/0/2` no longer exists and `Data/0` still exists

#### Scenario: A file already at the target path is not touched

- **WHEN** the write finds a file already at the path where its `.emlx` file would go
- **THEN** the write SHALL fail without writing any row
- **AND** the system SHALL NOT remove or change that file or its directory

##### Example: an existing 20000.emlx is left as it was
- **GIVEN** `Data/0/2/Messages/20000.emlx` already exists with other content
- **WHEN** the write for row id 20000 runs
- **THEN** the write fails, and the file keeps its content and its directory remains

#### Scenario: A recorded directory that no longer exists is skipped

- **WHEN** a committed write that created directories for its `.emlx` file is reversed, and another process has already removed the deepest of those directories
- **THEN** the system SHALL skip that directory and remove the remaining directories the write created
- **AND** reversing the write SHALL succeed

##### Example: a vanished Messages directory does not stop the cleanup
- **GIVEN** a committed write that created `Data/0`, `Data/0/2` and `Data/0/2/Messages` for `20000.emlx`, and another process removed `20000.emlx` and then `Data/0/2/Messages`
- **WHEN** the write is reversed
- **THEN** the reversal succeeds, `Data/0/2` and `Data/0` no longer exist, and `Data` still exists

#### Scenario: A removal that fails for another reason is noted and stops the cleanup

- **WHEN** a committed write is reversed and removing a directory it created fails for a reason other than the directory not being empty or no longer existing
- **THEN** the system SHALL write a line naming that directory and the reason to stderr
- **AND** the system SHALL keep that directory and every directory above it
- **AND** reversing the write SHALL succeed

##### Example: a permission failure on Messages is noted on stderr
- **GIVEN** a committed write that created `Data/0`, `Data/0/2` and `Data/0/2/Messages` for `20000.emlx`, and `Data/0/2` made read-only so `Data/0/2/Messages` cannot be removed
- **WHEN** the write is reversed
- **THEN** the reversal succeeds, `20000.emlx` is removed, `Data/0/2/Messages`, `Data/0/2` and `Data/0` remain, and stderr has a line containing `could not remove created directory` and the path of `Data/0/2/Messages`

