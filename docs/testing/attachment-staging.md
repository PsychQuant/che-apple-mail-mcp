# Native attachment staging check

Refs #402. `AttachmentDestinationLiveTests` exercises Mail's real `save` command
against the production private staging and publication implementation. It checks
0700 stage permissions, byte-for-byte publication, overwrite, distinct stage
names, and cleanup after success and a synthetic error after Mail has written.
It does not test account selection, remote attachment download, or receipt identity.
The imported local mailbox has no account UUID; selection for this fixture uses
its unique name, subject, and Message-ID, while production account resolution is
covered separately.

The test is skipped unless `MAIL_APP_INTEGRATION_TESTS=1` is set. Use a synthetic
local mailbox only. Do not select an existing personal message or send mail.

Prepare and import the one-message fixture with Python's standard library:

```python
from email.message import EmailMessage
from email.policy import SMTP
from pathlib import Path
import json, mailbox, os, subprocess, tempfile, uuid

root = Path(tempfile.mkdtemp(prefix="idd402-native-"))
token = "IDD402Native-" + str(uuid.uuid4())
folder = root / (token + ".mbox")
folder.mkdir(mode=0o700)
msg = EmailMessage(policy=SMTP)
msg["From"] = msg["To"] = "fixture@example.invalid"
msg["Subject"] = token
msg["Message-ID"] = "<" + token + "@example.invalid>"
msg.set_content("Synthetic local attachment fixture; never send.")
msg.add_attachment(b"IDD402 native attachment staging fixture\x00\x01\x02\xff\n",
                   maintype="application", subtype="octet-stream", filename="idd402.bin")
box = mailbox.mbox(folder / "mbox")
box.add(msg)
box.flush()
box.close()
os.chmod(folder / "mbox", 0o600)
script = 'with timeout of 15 seconds\ntell application "Mail" to import Mail mailbox at POSIX file ' + json.dumps(str(folder)) + '\nend timeout'
print("Fixture token:", token, "\nLocal source:", root, flush=True)
subprocess.run(["osascript", "-e", script], check=True, timeout=20)
```

Run only the gated test from the checkout, replacing the token with the printed
value (not the literal placeholder):

```sh
MAIL_APP_INTEGRATION_TESTS=1 CHE_MAIL_ATTACHMENT_FIXTURE_TOKEN=IDD402Native-UUID \
  swift test --filter AttachmentDestinationLiveTests
```

Afterward, locate the exact UUID-named mailbox under Mail's local Import folder.
Verify that it contains only the one synthetic message and no child mailboxes,
then delete that specific mailbox through Mail's UI. Do not empty any Trash or
remove the shared Import folder. On the tested Mail version, AppleScript mailbox
`delete` returned `-10000`; the UI action worked. Confirm absence using:

```applescript
tell application "Mail" to count (every mailbox whose name is "IDD402Native-UUID")
```

The result must be 0. Remove the printed local source directory after cleanup.
The test itself always removes its output directory and the production staging
code removes its stages; neither removes the imported Mail fixture.

## Recorded native result

2026-09-17: one live XCTest passed on the #402 implementation, using a generated
local fixture. Both native saves produced the expected 45 bytes. The second save
was followed by a deliberate producer error; the destination remained unchanged
and both private stage directories were absent. The exact imported fixture was
removed via Mail UI, and a separate native query returned zero matching mailboxes.
This supplies the staging-specific live gate; complete IDD review remains separate.
