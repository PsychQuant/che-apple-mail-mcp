#!/usr/bin/env python3
"""#488 live experiment: the read-toggle gap of the direct-write upload trigger.

Runs `create_draft` through an EXPERIMENT build (scripts/experiments/488-toggle-gap/exp488.patch
applied: the gap comes from CHE_MAIL_EXPERIMENT_488_GAP and ensureRead logs `EXP488|...` lines),
N drafts per gap value, on a test account. For every draft it records:
  - the local read state at the first look after upload confirmation (before any read re-assert),
  - the local read state after the re-assert (when one was needed),
  - the upload-confirm time from the tool result,
  - after the batch has synced: how many copies are in the account's Drafts and All Mail
    mailboxes, and the read flag of the All Mail copy (the server's state).

Environment:
  EXP488_BIN          path to the signed experiment binary
  EXP488_FROM_FILE    file holding the test account address (read, never printed)
  EXP488_DRAFTS_MB    Envelope Index ROWID of the test account's Drafts mailbox
  EXP488_ALLMAIL_MB   Envelope Index ROWID of the test account's All Mail mailbox
Usage: live488.py <runs_per_gap> <out_json> <gap> [<gap> ...]
"""
import json, os, re, sqlite3, subprocess, sys, tempfile, time

BIN = os.environ["EXP488_BIN"]
FROM = open(os.environ["EXP488_FROM_FILE"]).read().strip()
DRAFTS_MB = int(os.environ["EXP488_DRAFTS_MB"])
ALLMAIL_MB = int(os.environ["EXP488_ALLMAIL_MB"])
DB = os.path.expanduser("~/Library/Mail/V10/MailData/Envelope Index")
runs_per_gap, out_path, gaps = int(sys.argv[1]), sys.argv[2], sys.argv[3:]


def create(gap, subject):
    env = dict(os.environ, CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT="1", CHE_MAIL_EXPERIMENT_488_GAP=gap)
    env.pop("CHE_MAIL_COMPOSE_TIMING_CSV", None)
    with tempfile.TemporaryFile("w+") as err:
        p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                             text=True, bufsize=1, env=env)
        nid = [0]

        def rpc(method, params=None, notify=False):
            msg = {"jsonrpc": "2.0", "method": method}
            if params is not None:
                msg["params"] = params
            if not notify:
                nid[0] += 1
                msg["id"] = nid[0]
            p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
            if notify:
                return None
            while True:
                o = json.loads(p.stdout.readline())
                if o.get("id") == nid[0]:
                    return o

        try:
            rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                               "clientInfo": {"name": "exp488", "version": "0"}})
            rpc("notifications/initialized", notify=True)
            r = rpc("tools/call", {"name": "create_draft", "arguments": {
                "to": ["probe488@example.invalid"], "subject": subject,
                "body": "#488 toggle-gap experiment probe. Synthetic content; safe to delete.", "from_address": FROM}})
        finally:
            p.stdin.close()
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                p.kill()
        err.seek(0)
        exp = [line.strip() for line in err if line.startswith("EXP488|")]
    res = r.get("result") or {}
    text = " ".join(c.get("text", "") for c in res.get("content", [])).replace(FROM, "<from>")
    first = next((re.search(r"first=(\w+)", l).group(1) for l in exp if "first=" in l), None)
    after = next((re.search(r"after=(\w+)", l).group(1) for l in exp if "after=" in l), None)
    m = re.search(r"uploaded ([0-9.]+)s after the trigger", text)
    return {"gap": gap, "subject": subject, "isError": bool(res.get("isError")),
            "uploaded": bool(m), "upload_s": float(m.group(1)) if m else None,
            "first": first, "after": after, "text": text[:200]}


def copies(subject):
    c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    rows = c.execute("SELECT m.mailbox, m.read FROM messages m JOIN subjects s ON s.ROWID = m.subject "
                     "WHERE s.subject = ?", (subject,)).fetchall()
    c.close()
    drafts = [r for r in rows if r[0] == DRAFTS_MB]
    allmail = [r for r in rows if r[0] == ALLMAIL_MB]
    return {"drafts_n": len(drafts), "drafts_read": [r[1] for r in drafts],
            "allmail_n": len(allmail), "allmail_read": [r[1] for r in allmail]}


results = []
for gap in gaps:
    batch = []
    for i in range(1, runs_per_gap + 1):
        rec = create(gap, f"[idd-488-probe] g{gap} #{i}")
        batch.append(rec)
        print(f"gap {gap} #{i}: err={rec['isError']} up={rec['upload_s']} first={rec['first']} after={rec['after']}",
              flush=True)
        time.sleep(2)
    deadline = time.time() + 180
    while time.time() < deadline:
        states = [copies(r["subject"]) for r in batch]
        if all(s["allmail_n"] >= 1 for s in states):
            break
        subprocess.run(["osascript", "-e", 'tell application "Mail" to check for new mail'], capture_output=True)
        time.sleep(5)
    time.sleep(10)  # let flags settle once every copy is present
    for r in batch:
        r.update(copies(r["subject"]))
    results.extend(batch)
    print(f"gap {gap}: synced copies " + ", ".join(f"{r['drafts_n']}/{r['allmail_n']}" for r in batch), flush=True)
    json.dump(results, open(out_path, "w"), ensure_ascii=False, indent=1)
