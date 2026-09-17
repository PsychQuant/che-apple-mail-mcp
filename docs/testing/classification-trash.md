# Native classification Trash check

Refs #356. `ClassificationTrashLiveTests` calls the real `classificationSource`
and `moveClassifiedMessage` controller methods, including their non-GUI
osascript transport and source/account/Message-ID/Trash-role checks. It first
supplies different expected source bytes and requires a refusal with the source
unchanged. Only after that conclusive refusal does it submit the actual source.
It then requires an empty source mailbox and one matching message in the
account's native Trash, with unchanged normalized source digest.

This is a native-boundary test, not an end-to-end policy/plan/SQLite test. Policy
approvals, plan freshness, and audit authorization have separate integration
tests. The native test uses an isolated temporary empty policy store; it does
not approve a rule or modify the user's policy. It never sends mail or empties
Trash. Unknown outcomes stop the test; they are not automatically retried.

## Prepare the owned fixture

Use an existing test account that exposes exactly one native Trash role. Create
one new account mailbox named `IDD356Native-<UUID>` and import/move only the
synthetic message described below into it. Do not use an existing personal
message, Drafts, Inbox, or a mailbox containing other messages. Mail's Import
command initially creates a local mailbox; move the one synthetic message to
the dedicated account mailbox before running the test.

A standard-library example generates the importable local source without
operating Mail:

```python
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import format_datetime
from datetime import datetime, timezone
from pathlib import Path
import json, os, plistlib, tempfile, uuid

root = Path(tempfile.mkdtemp(prefix="idd356-native-"))
token = "IDD356Native-" + str(uuid.uuid4())
folder = root / (token + ".mbox")
folder.mkdir(mode=0o700)
message = EmailMessage(policy=SMTP)
message["From"] = "IDD356 Fixture <sender@example.invalid>"
message["To"] = "fixture@example.invalid"
message["Subject"] = token
message["Message-ID"] = "<" + token + "@example.invalid>"
message["Date"] = format_datetime(datetime.now(timezone.utc))
message.set_content("IDD356_BODY_" + token + "\nSynthetic fixture; never sent.\n", cte="7bit")
(folder / "mbox").write_bytes(b"From MAILER-DAEMON Thu Sep 17 00:00:00 2026\n" + message.as_bytes() + b"\n")
os.chmod(folder / "mbox", 0o600)
(folder / "Info.plist").write_bytes(plistlib.dumps({"MailboxName": str(folder)}))
print("Token:", token, "\nImport source:", folder)
```

After importing and staging the fixture, create a local JSON file with these
fields (all placeholders must be replaced):

```json
{
  "token": "IDD356Native-UUID",
  "accountID": "SELECTED_ACCOUNT_UUID",
  "id": "NATIVE_MESSAGE_ROW_ID",
  "sourceDigest": "SHA256_OF_NORMALIZED_NATIVE_SOURCE"
}
```

Read the current native message ID and `source` from that exact account mailbox,
not from the original `.mbox` file or a stale row ID. Normalize CRLF and CR to LF,
encode UTF-8, then compute SHA-256 for `sourceDigest`. Require one message, the
exact UUID subject/Message-ID/body marker, the expected sender, one
`fixture@example.invalid` recipient, and false flagged/deleted state. Do not
include source text in the JSON or publish account identifiers in test reports.
The test repeats source digest and native metadata checks before any move.

Run only the gated test from the checkout:

```sh
MAIL_APP_INTEGRATION_TESTS=1 \
CHE_MAIL_CLASSIFICATION_FIXTURE_JSON=/absolute/path/to/fixture.json \
  swift test --filter ClassificationTrashLiveTests
```

Without the opt-in flag, the test skips before reading the fixture or contacting
Mail. Its policy directory uses a POSIX-resolved temporary path so the production
store's no-symlink traversal remains enabled.

## Inspect and clean up

After success, the source mailbox must be empty and the single owned message
must be in the account's actual Trash. Leave that message recoverable; do not
empty Trash. Remove only the newly created, confirmed-empty account mailbox and
local import mailbox. Never remove a pre-existing shared Import folder. Mail
labels mailbox deletion irreversible, so an operator must confirm that action
at cleanup time. If cleanup is deferred, record the exact retained empty
mailboxes rather than claiming complete cleanup.

On the tested Mail version, native mailbox `delete` returns `-10000`; use the
Mail UI after checking the exact mailbox and obtaining the applicable cleanup
confirmation. Do not substitute deleting Mail's database or filesystem storage.

## Recorded native result

2026-09-17, macOS 27 / Mail 16: one actual native XCTest passed in 8.36 seconds.
The mismatched-source operation refused; the matching source moved to the
unique native Trash; the source mailbox became empty; the message retained its
Message-ID, sender, subject, and normalized source digest. The generated source
was 466 UTF-8 bytes. The isolated policy store was removed by test teardown.

An earlier attempt stopped before the mover while creating the test policy
store through a `/var` alias. A fresh native read confirmed the message remained
unchanged. The harness now uses POSIX `realpath`, matching the other store tests.
The successful retry was not a retry of an uncertain move.

The synthetic message remains recoverable in Trash. The account mailbox and a
new local Import parent with its empty fixture child are retained pending the
operator's irreversible-mailbox-deletion confirmation. Full IDD review is a
separate, still-open gate; this result does not verify real user rules or Gmail
server synchronization.
