#!/usr/bin/env python3
"""#497 live check: the direct-write upload-confirmation poll at 100 ms.

Runs `create_draft` N times through a signed build of this branch with the
opt-in direct-write path and step timing on, on a test account. For every draft
it records the outcome, the upload-confirm time reported by the tool, the
`trigger_sent -> uploaded` span from the timing CSV, and, once the batch has
synced, how many copies sit in the account's Drafts and All Mail mailboxes and
their local read flags. The tool's result text is not stored.

Environment:
  EXP497_BIN          path to the signed binary built from this branch
  EXP497_FROM_FILE    file holding the test account address (read, never printed)
  EXP497_DRAFTS_MB    Envelope Index ROWID of the test account's Drafts mailbox
  EXP497_ALLMAIL_MB   Envelope Index ROWID of the test account's All Mail mailbox
Usage: live497.py <runs> <timing_csv> <out_json>
"""
import csv, json, os, re, sqlite3, subprocess, sys, time

BIN = os.environ["EXP497_BIN"]
FROM = open(os.environ["EXP497_FROM_FILE"]).read().strip()
DRAFTS_MB = int(os.environ["EXP497_DRAFTS_MB"])
ALLMAIL_MB = int(os.environ["EXP497_ALLMAIL_MB"])
DB = os.path.expanduser("~/Library/Mail/V10/MailData/Envelope Index")
runs, csv_path, out_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]


def create(subject):
    env = dict(os.environ, CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT="1", CHE_MAIL_COMPOSE_TIMING_CSV=csv_path)
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
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
                           "clientInfo": {"name": "exp497", "version": "0"}})
        rpc("notifications/initialized", notify=True)
        t0 = time.time()
        r = rpc("tools/call", {"name": "create_draft", "arguments": {
            "to": ["probe497@example.invalid"], "subject": subject,
            "body": "#497 upload-poll probe. Synthetic content; safe to delete.", "from_address": FROM}})
        seconds = time.time() - t0
    finally:
        p.stdin.close()
        try:
            p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            p.kill()
    res = r.get("result") or {}
    text = " ".join(c.get("text", "") for c in res.get("content", []))
    m = re.search(r"uploaded ([0-9.]+)s after the trigger", text)
    return {"subject": subject, "isError": bool(res.get("isError")), "seconds": round(seconds, 3),
            "direct": "experimental direct-write path" in text, "uploaded": bool(m),
            "upload_s": float(m.group(1)) if m else None,
            "read_note": "unread" in text or "could not be read" in text}


def copies(subject):
    c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    rows = c.execute("SELECT m.ROWID, m.mailbox, m.read FROM messages m JOIN subjects s ON s.ROWID = m.subject "
                     "WHERE s.subject = ?", (subject,)).fetchall()
    c.close()
    return {"drafts_rowids": [r[0] for r in rows if r[1] == DRAFTS_MB],
            "drafts_read": [r[2] for r in rows if r[1] == DRAFTS_MB],
            "allmail_n": sum(1 for r in rows if r[1] == ALLMAIL_MB),
            "allmail_read": [r[2] for r in rows if r[1] == ALLMAIL_MB]}


def spans_from_csv():
    """trigger_sent -> uploaded per run, from the direct segment's ms_since_start."""
    by_run = {}
    with open(csv_path, newline="") as f:
        for row in csv.DictReader(f):
            if row.get("path") != "direct":
                continue
            by_run.setdefault(row["run_id"], {})[row["step"]] = float(row["ms_since_start"])
    out = []
    for steps in by_run.values():
        if "trigger_sent" in steps and "uploaded" in steps:
            out.append(round(steps["uploaded"] - steps["trigger_sent"], 1))
    return out


results = []
for i in range(1, runs + 1):
    rec = create(f"[idd-497-probe] #{i}")
    results.append(rec)
    print(f"#{i}: err={rec['isError']} direct={rec['direct']} up={rec['upload_s']} t={rec['seconds']}", flush=True)
    time.sleep(3)

deadline = time.time() + 180
while time.time() < deadline:
    if all(copies(r["subject"])["allmail_n"] >= 1 for r in results):
        break
    subprocess.run(["osascript", "-e", 'tell application "Mail" to check for new mail'], capture_output=True)
    time.sleep(5)
time.sleep(10)  # let flags settle once every copy is present
for r in results:
    r.update(copies(r["subject"]))

report = {"runs": results, "trigger_sent_to_uploaded_ms": spans_from_csv(), "poll_ms": 100,
          "date": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
json.dump(report, open(out_path, "w"), ensure_ascii=False, indent=1)
print("copies (drafts/allmail):", ", ".join(f"{len(r['drafts_rowids'])}/{r['allmail_n']}" for r in results))
