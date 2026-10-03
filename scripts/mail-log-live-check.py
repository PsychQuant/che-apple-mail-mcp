"""Live check for get_mail_log_events (#465): drive a SIGNED server binary over MCP stdio and compare it with
the real unified log. Prints counts, times and static event templates only — never a composed log message.

    python3 scripts/mail-log-live-check.py /path/to/signed/CheAppleMailMCP

Needs an admin-group user. Every window is DISCOVERED from the current log (the busiest IMAPConnection
millisecond of the last 24 hours, and the minutes around it), so the script can be re-run at any time; when
Mail has been idle and there is nothing to discover, the affected checks report SKIP and say why. The #463
chain checks use the windows #465 was investigated on (2026-10-02, Taipei) and SKIP once those age out."""
import json, subprocess, sys, re, time, collections
BIN = sys.argv[1]
EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}")
UUID  = re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")
MSGID = re.compile(r"<[^<>\s@]+@[^<>\s]+>")
PLACEHOLDER = re.compile(r"%(\{[^}]*\})?[-+ #0]*[0-9*]*(\.[0-9*]+)?(hh|h|ll|l|z|t|j|q|L)?[A-Za-z@]")
def shapes(text):
    """Look for identifier shapes in the bytes sent, after blanking printf placeholders (static templates).
    A template such as <%{public}@@%{public}@> is not data."""
    t = re.sub(r"PH(@PH)+", "PH", PLACEHOLDER.sub("PH", text))   # "<%@@%@>" is a template for a Message-ID, not one
    return bool(EMAIL.search(t) or UUID.search(t) or MSGID.search(t))

p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
import atexit
atexit.register(lambda: (p.poll() is None) and p.kill())       # never leave the server running
_id = 0
def rpc(method, params=None, notify=False):
    global _id
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None: msg["params"] = params
    if not notify:
        _id += 1; msg["id"] = _id
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    if notify: return None
    while True:
        line = p.stdout.readline()
        if not line: raise SystemExit("server closed stdout")
        r = json.loads(line)
        if r.get("id") == _id: return r
def call(args):
    r = rpc("tools/call", {"name": "get_mail_log_events", "arguments": args})
    res = r.get("result", {})
    text = "".join(c.get("text", "") for c in res.get("content", []))
    return res.get("isError", False), text

ok = True
def check(name, cond, extra=""):
    global ok; ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name + (f"  [{extra}]" if extra else ""))

rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "live-465", "version": "0"}})
rpc("notifications/initialized", notify=True)
tools = rpc("tools/list")["result"]["tools"]
names = [t["name"] for t in tools]
desc = next(t["description"] for t in tools if t["name"] == "get_mail_log_events")
check("tool description fits the 2,048-character host limit", len(desc) <= 2048, f"{len(desc)} chars")
check("tools/list contains get_mail_log_events", "get_mail_log_events" in names, f"{len(names)} tools")

# 1. default brief, last 10 minutes
t0 = time.time(); err, text = call({}); dt = time.time() - t0
r = json.loads(text)
ev = r["results"]
check("default call: status ok or empty, within the 64 KiB cap", not err and r["status"] in ("ok", "no_events_in_window") and len(text.encode()) <= 65536,
      f"returned={r['returned']} stopped_by={r['stopped_by']} accounts_seen={r['accounts_seen']} {dt:.1f}s bytes={len(text)}")
check("brief: no email / UUID / Message-ID shape anywhere in the bytes sent", not shapes(text))
check("brief: every event has exactly the documented 8 fields", all(set(e) == {"time","subsystem","category","event","kind","args","activity","account"} for e in ev))
check("brief: accounts are aliases", all(e["account"] is None or re.fullmatch(r"[A-Z]{1,3}", e["account"]) for e in ev))
check("brief: args hold only integers or null", all(all(a is None or isinstance(a, int) for a in e["args"]) for e in ev))
print("     kinds:", dict(collections.Counter(e["kind"] for e in ev)), "| categories:", dict(collections.Counter(e["category"] for e in ev).most_common(4)))
check("window and coverage reported with offsets", re.search(r"[+-]\d\d:\d\d$|Z$", r["window"]["start"]) and r["coverage"]["source"] == "log show --style ndjson", r["window"]["start"])

RETRIES = collections.Counter()
def events(args):
    # `unavailable` / `deadline_exceeded` is the tool reporting honestly that the log reader did not get past the
    # cursor within 30 s (it happens when another `log show` loads the machine). Retry that one case, and count it.
    for attempt in range(3):
        err, text = call(args); r = json.loads(text)
        if not err and r["status"] == "unavailable" and r.get("reason") == "deadline_exceeded" and attempt < 2:
            RETRIES["deadline_exceeded"] += 1; time.sleep(2); continue
        break
    assert not err and r["status"] in ("ok", "no_events_in_window"), "unexpected status " + str(r.get("status")) + " " + str(r.get("reason"))
    return r, text
def raw_lines(start, end, cats, extra=""):
    pred = 'subsystem IN {"com.apple.email","com.apple.mail"} AND category IN {' + ",".join(f'"{c}"' for c in cats) + '}' + extra
    out = subprocess.run(["/usr/bin/log", "show", "--style", "ndjson", "--start", start, "--end", end, "--predicate", pred], capture_output=True, text=True).stdout
    rows = []
    for l in out.splitlines():
        try: o = json.loads(l)
        except Exception: continue
        if "formatString" in o: rows.append(o)
    return rows
def iso(stamp):          # "2026-10-02 12:42:26.478123+0800" -> "2026-10-02T12:42:26.478+08:00"
    return stamp[:10] + "T" + stamp[11:23] + stamp[-5:-2] + ":" + stamp[-2:]
def logtime(d): return d.strftime("%Y-%m-%d %H:%M:%S")
def isotime(d): return d.strftime("%Y-%m-%dT%H:%M:%S.000") + OFFSET

# 2. the #463 chain (2026-10-02 12:42 +08:00), NARROW queries; SKIP once the log no longer holds it
r1, t1 = events({"around": "2026-10-02T12:42:26.4+08:00", "radius_seconds": 3, "categories": ["EDLocalActionPersistence", "Drafts"]})
r2, t2 = events({"around": "2026-10-02T12:42:26.5+08:00", "radius_seconds": 1, "categories": ["IMAPSyncActivity"]})
r3, t3 = events({"since": "2026-10-02T12:42:47.300+08:00", "until": "2026-10-02T12:42:47.600+08:00", "categories": ["IMAPConnection"]})
e1, e2, e3 = r1["results"], r2["results"], r3["results"]
held = {name: len(raw_lines(a, b, cats)) for name, a, b, cats in (
    ("action", "2026-10-02 12:42:23", "2026-10-02 12:42:30", ["EDLocalActionPersistence", "Drafts"]),
    ("engine", "2026-10-02 12:42:25", "2026-10-02 12:42:28", ["IMAPSyncActivity"]),
    ("receipt", "2026-10-02 12:42:47", "2026-10-02 12:42:48", ["IMAPConnection"]))}
def chain(name, label, cond):
    if held[name] == 0: print(f"SKIP #463 chain: {label} — aged out of the unified log (raw log show returns 0)")
    else: check(f"#463 chain: {label}", cond)
chain("action", "'Created … action' event", any(e["event"].startswith("Created %{public}@ action") for e in e1))
chain("action", "'Processing action' event", any("Processing action" in e["event"] for e in e1))
chain("engine", "'Received … new local message actions' event", any("new local message actions" in e["event"] for e in e2))
chain("receipt", "upload receipt recognized as known event", any(e["kind"] == "known" and e["event"] == "imap.append_uid_received" for e in e3))
check("no email/UUID/Message-ID in any #463 output", not any(shapes(t) for t in (t1, t2, t3)))

# 3. discover windows from the current log: the busiest IMAPConnection millisecond of the last 24 hours
import datetime as _dt
now = _dt.datetime.now().replace(microsecond=0)
OFFSET = _dt.datetime.now().astimezone().strftime("%z"); OFFSET = OFFSET[:3] + ":" + OFFSET[3:]
recent = raw_lines(logtime(now - _dt.timedelta(hours=24)), logtime(now - _dt.timedelta(minutes=3)), ["IMAPConnection"])
groups = collections.Counter(o["timestamp"][:23] for o in recent)
if not groups:
    print("SKIP sections 3a-3d: no IMAPConnection events in the last 24 hours to build windows from")
else:
    burst_ms, burst_n = groups.most_common(1)[0]
    burst = _dt.datetime.strptime(burst_ms, "%Y-%m-%d %H:%M:%S.%f")
    print(f"     discovered: busiest millisecond {burst_ms[11:]} with {burst_n} IMAPConnection events")

    # 3a. paging with the position cursor over a 2-second slice around the burst
    win = {"since": isotime(burst - _dt.timedelta(seconds=1)), "until": isotime(burst + _dt.timedelta(seconds=1)), "categories": ["IMAPConnection"]}
    # Two references. Raw `log show` gives times, templates and activity ids; a page-through at limit 1000 gives the
    # tool's full tuples (args included). One unpaged call is not a reference: a busy slice exceeds the 64 KiB cap.
    slice_raw = [o for o in raw_lines(logtime(burst - _dt.timedelta(seconds=1)), logtime(burst + _dt.timedelta(seconds=2)), ["IMAPConnection"])
                 if win["since"] <= iso(o["timestamp"]) <= win["until"]]
    full_tuple = lambda e: (e["time"], e["event"], tuple(e["args"]), e["activity"])
    def page_all(limit):
        out, since, offset, pages = [], win["since"], 0, 0
        while pages < 2000:
            pages += 1
            args = {**win, "since": since, "limit": limit}
            if offset: args["offset"] = offset
            r, _ = events(args)
            out += r["results"]
            if not r["truncated"]: return out, pages, True
            if (r["next_start"], r["next_offset"]) == (since, offset): return out, pages, False
            since, offset = r["next_start"], r["next_offset"]
        return out, pages, False
    ref, ref_pages, ref_done = page_all(1000)
    # a known event or a withheld template does not echo the raw template: compare its time and activity only
    matches_raw = lambda e, o: (e["time"] == iso(o["timestamp"]) and e["activity"] == o.get("activityIdentifier", 0)
                                and (e["kind"] == "known" or e["event"] in ("<template withheld>", o["formatString"])))
    check("paging reference (limit 1000) equals raw log show — times, templates, activity ids, order",
          ref_done and len(ref) == len(slice_raw) and all(matches_raw(e, o) for e, o in zip(ref, slice_raw)),
          f"pages={ref_pages} events={len(ref)}/{len(slice_raw)} (raw log show)")
    for limit in (1, 3, 15):
        got, pages, done = page_all(limit)
        check(f"paging limit={limit} through the burst: terminates, every event exactly once, identical to the reference (args included)",
              done and [full_tuple(e) for e in got] == [full_tuple(e) for e in ref], f"pages={pages} events={len(got)}/{len(ref)}")

    # 3b. equivalence with raw log show over the 8 minutes around the burst (times, templates, order)
    a, b = burst - _dt.timedelta(minutes=4), burst + _dt.timedelta(minutes=4)
    lo, hi = isotime(a), isotime(b)                        # the exact bounds the tool is asked for
    raw_eq = [o for o in raw_lines(logtime(a), logtime(b + _dt.timedelta(seconds=1)), ["IMAPConnection"]) if lo <= iso(o["timestamp"]) <= hi]
    tool, _ = events({"since": lo, "until": hi, "categories": ["IMAPConnection"], "limit": 1000})
    n = len(tool["results"])
    same = all(e["time"] == iso(o["timestamp"]) and (e["event"] == o["formatString"] or e["kind"] == "known" or e["event"] == "<template withheld>")
               for e, o in zip(tool["results"], raw_eq))
    check("equivalence: brief events equal raw log show — ms timestamps, templates, order",
          n > 0 and same and (n == len(raw_eq) if not tool["truncated"] else n <= len(raw_eq)),
          f"raw={len(raw_eq)} tool={n} truncated={tool['truncated']}")

    # 3c. size_cap paging in detailed mode over 4 minutes around the burst: every event exactly once; a message
    #     over 8,192 bytes comes back as a prefix of the original with message_truncated (the cut rule).
    a, b = burst - _dt.timedelta(minutes=2), burst + _dt.timedelta(minutes=2)
    lo, hi = isotime(a), isotime(b)
    raw_d = [o for o in raw_lines(logtime(a), logtime(b + _dt.timedelta(seconds=1)), ["IMAPConnection"]) if lo <= iso(o["timestamp"]) <= hi]
    got, since, offset, pages, caps, biggest, stalled = [], lo, 0, 0, 0, 0, False
    while pages < 1000:
        pages += 1
        args = {"detail": "detailed", "since": since, "until": hi, "categories": ["IMAPConnection"], "limit": 1000}
        if offset: args["offset"] = offset
        err, text = call(args); r = json.loads(text)
        biggest = max(biggest, len(text.encode())); caps += r["stopped_by"] == "size_cap"
        got += r["results"]
        if not r["truncated"]: break
        if (r["next_start"], r["next_offset"]) == (since, offset): stalled = True; break
        since, offset = r["next_start"], r["next_offset"]
    # The cut rule, written out independently: the longest prefix of at most 8,192 UTF-8 bytes that ends at a safe
    # point — next to whitespace (both CharacterSet and ICU \s; U+200B is not), just before `<`, just after `>`.
    # CUT_WS mirrors what the Swift side computes at run time on macOS 27.2 (CharacterSet ∩ ICU \s); if a later
    # OS changes either set, this check reports a mismatch first — the safe direction.
    CUT_WS = {chr(c) for c in [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, *range(0x2000, 0x200B)]}
    def expected_shown(raw):
        if len(raw.encode()) <= 8192: return raw
        prefix, used = [], 0
        for ch in raw:
            w = len(ch.encode())
            if used + w > 8192: break
            prefix.append(ch); used += w
        nxt = raw[len(prefix)] if len(prefix) < len(raw) else None
        end = len(prefix)
        while end > 0:
            before, after = prefix[end - 1], (prefix[end] if end < len(prefix) else nxt)
            if before in CUT_WS or before == ">" or (after is not None and (after in CUT_WS or after == "<")): break
            end -= 1
        return "".join(prefix[:end])
    long_msgs = 0
    def matches(e, o):
        global long_msgs
        raw = o["eventMessage"]
        if e["time"] != iso(o["timestamp"]): return False
        if len(raw.encode()) > 8192: long_msgs += 1
        return e["message"] == expected_shown(raw) and bool(e.get("message_truncated")) == (len(raw.encode()) > 8192)
    same = len(got) == len(raw_d) and all(matches(e, o) for e, o in zip(got, raw_d))
    check("size_cap paging in detailed mode: every event exactly once, messages follow the cut rule, no stall, every page within the cap",
          not stalled and same and biggest <= 65536,
          f"raw={len(raw_d)} paged={len(got)} pages={pages} size_cap_pages={caps} long_messages={long_msgs} max_bytes={biggest}")

    # 3d. a one-millisecond window on a whole second (log show itself returns nothing for --start T --end T)
    whole = sorted(ms for ms in groups if ms.endswith(".000"))
    if not whole:
        print("SKIP one-millisecond window on a whole second: no IMAPConnection event at .000 in the last 24 hours")
    else:
        ms = max(whole, key=lambda m: groups[m])
        zw, _ = events({"since": ms[:10] + "T" + ms[11:] + OFFSET, "until": ms[:10] + "T" + ms[11:] + OFFSET, "categories": ["IMAPConnection"], "limit": 1000})
        check("one-millisecond window on a whole second returns that millisecond's events", zw["returned"] == groups[ms] and not zw["truncated"],
              f"{ms[11:]}: raw {groups[ms]}, tool {zw['returned']}")

# 4. receipt census: every line in the log store that CONTAINS "APPENDUID" is classified by the rule's own
#    description — receipt-shaped (the line's own `Read: `, a dotted-digit tag, the code, nothing after it) or
#    not — and, per millisecond, the tool must report exactly as many receipts as there are receipt-shaped lines.
RECEIPT = re.compile(r"\A(?=[0-9.]{1,16} )[0-9]+(?:\.[0-9]+)* OK \[APPENDUID \(\s*[0-9]+\s*(?:,\s*[0-9]+\s*)+\)\]\s*\Z")
def receipt_shaped(m):
    if m.startswith("Read: "): rest = m[6:]
    else:
        i = m.find("] <"); j = m.find("]> ", i + 3) if i >= 0 else -1
        if not m.startswith("[") or i < 0 or j < 0 or "\n" in m[:j] or not m[j + 3:].startswith("Read: "): return False
        rest = m[j + 9:]
    return bool(RECEIPT.match(rest))
census = raw_lines(logtime(now - _dt.timedelta(hours=48)), logtime(now), ["IMAPConnection"], ' AND eventMessage CONTAINS "APPENDUID"')
expected = collections.Counter(o["timestamp"][:23] for o in census if receipt_shaped(o["eventMessage"]))
others = sum(1 for o in census if not receipt_shaped(o["eventMessage"]))
wrong = 0
for ms in sorted({o["timestamp"][:23] for o in census}):
    stamp = ms[:10] + "T" + ms[11:] + OFFSET
    r, _ = events({"since": stamp, "until": stamp, "categories": ["IMAPConnection"], "limit": 1000})
    known = sum(1 for e in r["results"] if e["kind"] == "known" and e["event"] == "imap.append_uid_received")
    wrong += known != expected[ms]
if not census:
    print("SKIP receipt census: no line containing APPENDUID in the last 48 h (Mail uploaded no draft)")
else:
    check("receipt census: per millisecond, the tool reports exactly the receipt-shaped lines as receipts (no miss, no false receipt)",
          wrong == 0, f"{sum(expected.values())} receipt-shaped, {others} other APPENDUID lines, {wrong} milliseconds wrong (last 48 h)")

# 5. detailed + redaction (do not print messages)
err, text = call({"detail": "detailed", "limit": 5, "redact_identifiers": True, "categories": ["IMAPSyncActivity"]})
r = json.loads(text)
check("detailed: flagged sensitive with the do-not-paste notice", r["contains_sensitive"] is True and "public issues" in (r["notice"] or ""))
check("detailed+redact: raw message present, redaction declared best-effort",
      all("message" in e and "process" in e for e in r["results"]) and "best-effort" in r["redaction"]["note"])
check("detailed+redact: no email-shaped string survives in the messages", not EMAIL.search(" ".join(e["message"] for e in r["results"])))

# 6. refusals
err, text = call({"since": "2026-10-02 12:40:00"})
check("naive timestamp refused naming the format", err and "ISO 8601" in text and "offset" in text)
err, text = call({"contains": "x"})
check("contains refused in brief", err and "detailed" in text)

# 7. empty window far in the past: honest empty, not a negative claim
err, text = call({"since": "2026-10-01T20:00:00+08:00", "until": "2026-10-01T20:10:00+08:00"})
r = json.loads(text)
check("old window: no_events_in_window with the absence notice", r["status"] == "no_events_in_window" and "does not establish" in r["notice"], f"returned={r['returned']}")

p.stdin.close(); p.terminate()
if RETRIES: print(f"     note: {sum(RETRIES.values())} call(s) retried after deadline_exceeded")
print("\nALL PASS" if ok else "\nSOME CHECKS FAILED")
sys.exit(0 if ok else 1)
