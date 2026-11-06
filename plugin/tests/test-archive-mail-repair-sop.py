#!/usr/bin/env python3
"""Pins on the shipped text of /archive-mail-repair-synthetic-ids (#525 vocabulary, #529 structure).

Two groups of tests live here.

Vocabulary (#525): the repair command reports a closed set of status words and `still-unparseable` reason codes. The
tests read the shipped SOP text, not a second copy of the lists: the table between the `archive-mail-repair-codes`
markers is the only definition, and everything else in the document must agree with it in both directions.

Structure (#529): the SOP is prose that an agent follows, so the recipes' tests cannot see most of it. The checkers
below are pure functions (SOP text in, list of problems out) and each pin has named mutations that the checker must
report, so a pin that only passes because the real text happens to be fine would show up here.

What the structural pins CANNOT catch (and no test in this repository does; the one behavioural check of the whole
procedure, an agent replay against a fixture archive, was left out on purpose in #529):
  * a clause whose wording is kept but whose meaning is reversed, or one that survives only as a negated mention;
  * a fragment moved to another sentence of the same section, or steps reordered inside a section;
  * the VALUES in a report template, only the field names are pinned;
  * whether an agent follows any clause: asking at P3, stopping when the recipe cannot run, never deleting a file;
  * a new rule added in prose without a pin (only reason and status codes are held to a closed list);
  * a new stop-report template that does not begin with a `status:` line.
`allowed-tools` is pinned separately by CommandAllowedToolsGuardTests.
"""
import json
from pathlib import Path
import re
import tempfile
import unittest


DOCUMENT = Path(__file__).resolve().parents[1] / "commands/archive-mail-repair-synthetic-ids.md"
STOP_STATUSES = ("environment-unavailable", "lookup-unavailable", "apply-unavailable", "apply-incomplete")

# Expected vocabulary at this point of the cluster. Each later commit that adds a word edits these two sets.
EXPECTED_STATUS = {
    "completed", "completed-with-residue", "environment-unavailable", "lookup-unavailable", "apply-unavailable", "apply-incomplete",
}
EXPECTED_REASONS = {
    "subject-unavailable", "sender-unavailable", "date-offset-missing", "date-unparseable",
    "search-truncated", "candidate-sender-unparseable", "candidate-date-unparseable", "no-match",
    "candidate-message-id-missing", "message-id-format-collision", "message-id-collision",
    "quarantine-destination-conflict",
    "old-key-entry-conflict", "existing-key-spelling-mismatch", "duplicate-unverifiable",
    "duplicate-content-drift", "dependent-group-rejected", "index-reference-conflict",
    "date-ambiguous-local-time",
}

DUPLICATES_FORMS = (
    re.compile(r"not evaluated"),
    re.compile(r"before (?:\d+|<N>) / after (?:\d+|<N>)"),
    re.compile(r"before (?:\d+|<N>) / after (?:\d+|<M>)（已搬移：.+）"),
    re.compile(r"unknown \(quarantine-inventory-unavailable\)"),
)

START, END = "<!-- archive-mail-repair-codes:start -->", "<!-- archive-mail-repair-codes:end -->"


def sop_text():
    return DOCUMENT.read_text()


def split_codes_block(text):
    """Return (codes block, everything else)."""
    if text.count(START) != 1 or text.count(END) != 1:
        raise AssertionError(f"the SOP must carry exactly one {START} ... {END} pair")
    head, rest = text.split(START, 1)
    block, tail = rest.split(END, 1)
    return block, head + tail


def table_rows(block, heading_prefix):
    """Reason/status codes listed under the heading that starts with `heading_prefix`, plus the heading itself."""
    lines = block.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(heading_prefix))
    codes = []
    for line in lines[start + 1:]:
        if line.startswith("#### "):
            break
        match = re.match(r"\| `([a-z]+(?:-[a-z]+)*)` \|", line)
        if match:
            codes.append(match.group(1))
    return lines[start], codes


def fenced_blocks(text):
    return re.findall(r"```[a-z]*\n(.*?)\n```", text, re.S)


class RepairVocabularyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = sop_text()
        cls.block, cls.outside = split_codes_block(cls.text)
        cls.status_heading, cls.status = table_rows(cls.block, "#### status")
        cls.reason_heading, cls.reasons = table_rows(cls.block, "#### still-unparseable")

    def test_the_two_tables_hold_exactly_the_documented_words(self):
        self.assertEqual(set(self.status), EXPECTED_STATUS)
        self.assertEqual(set(self.reasons), EXPECTED_REASONS)
        self.assertEqual(len(self.status), len(set(self.status)), "duplicate row in the status table")
        self.assertEqual(len(self.reasons), len(set(self.reasons)), "duplicate row in the reason table")

    def test_each_heading_states_a_closed_count_that_matches_its_rows(self):
        for heading, rows in ((self.status_heading, self.status), (self.reason_heading, self.reasons)):
            with self.subTest(heading=heading):
                self.assertIn("不得依性質相似類推", heading)
                self.assertEqual(int(re.search(r"只有這 (\d+) 類", heading).group(1)), len(rows))

    def test_every_status_and_reason_used_in_the_document_is_in_its_table(self):
        used_status = set(re.findall(r"\bstatus: ([a-z]+(?:-[a-z]+)*)", self.outside))
        used_reason = set(re.findall(r"still-unparseable: ([a-z]+(?:-[a-z]+)+)", self.outside))
        self.assertEqual(used_status - set(self.status), set(), "status word outside the table")
        self.assertEqual(used_reason - set(self.reasons), set(), "reason code outside the table")

    def test_every_table_word_is_used_somewhere_outside_the_table(self):
        for code in self.status + self.reasons:
            with self.subTest(code=code):
                self.assertRegex(self.outside, rf"(?<![a-z-]){re.escape(code)}(?![a-z-])")

    def test_the_retired_rekey_collision_code_does_not_appear_anywhere(self):
        self.assertNotIn("rekey-collision", self.text)

    def test_every_stop_report_template_carries_a_closed_duplicates_value(self):
        seen = set()
        for block in fenced_blocks(self.outside):
            match = re.search(r"^status: ([a-z-]+)$", block, re.M)
            if match is None or match.group(1) not in STOP_STATUSES:
                continue
            seen.add(match.group(1))
            with self.subTest(status=match.group(1)):
                value = re.search(r"^duplicates: (.+)$", block, re.M)
                self.assertIsNotNone(value, "stop report template without a duplicates field")
                self.assertTrue(any(form.fullmatch(value.group(1)) for form in DUPLICATES_FORMS),
                                f"duplicates value outside the four closed forms: {value.group(1)}")
        self.assertEqual(seen, set(STOP_STATUSES), "a stop report template is missing")

    def test_inline_reports_in_prose_carry_the_duplicates_field_too(self):
        prose = re.sub(r"```.*?```", "", self.outside, flags=re.S)
        inline = [p for p in prose.split("\n\n") if "repaired: 0" in p and "stage:" in p]
        self.assertTrue(inline, "no inline report found; the Step 1 prose report moved?")
        for paragraph in inline:
            with self.subTest(paragraph=paragraph[:40]):
                self.assertIn("duplicates:", paragraph)

    def test_the_four_duplicates_forms_are_listed_once_in_one_place(self):
        for phrase in ("not evaluated", "unknown (quarantine-inventory-unavailable)"):
            self.assertIn(phrase, self.outside)
        self.assertRegex(self.outside, r"before N / after M（已搬移")


class RepairInvocationTests(unittest.TestCase):
    """The --naive-date-zone flag must be declared where the host reads it and where the user reads it (#528)."""

    @classmethod
    def setUpClass(cls):
        cls.text = sop_text()

    def test_the_argument_hint_is_one_json_line_naming_the_flag(self):
        line = next(l for l in self.text.splitlines() if l.startswith("argument-hint:"))
        value = json.loads(line.split(":", 1)[1].strip())
        self.assertIn("--naive-date-zone", value)
        self.assertIn("<archive_target 或 output_dir>", value)

    def test_the_usage_section_states_the_four_rules(self):
        usage = self.text.split("## 用法", 1)[1].split("## Execution", 1)[0]
        for phrase in ("--naive-date-zone", "沒有預設值", "zoneinfo.available_timezones()", "±HH:MM",
                       "不是 `archive_target`", "沒有明確 offset", "不改寫"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, usage)

    def test_the_flag_is_not_suggested_with_any_particular_zone_in_reports(self):
        # A hint that names a zone would be a default in disguise.
        hints = [l for l in self.text.splitlines() if "date-offset-missing" in l and "重跑" in l]
        for line in hints:
            self.assertNotRegex(line, r"Asia/|UTC|[+-]\d\d:\d\d")




# ---------------------------------------------------------------------------------------------------------------------
# Structural pins (#529): pure functions, SOP text in, problems out.
# ---------------------------------------------------------------------------------------------------------------------

PROBE = 'search_emails(field: "subject", query: "archive-mail repair capability probe", projection: "summary", dedup: "none", limit: 1)'

# Frozen copy of the fields each report template must carry. A second copy on purpose: change both when a template changes.
REQUIRED_FIELDS = {
    "environment-unavailable": ("status", "stage", "repaired", "still-unparseable", "pending", "duplicates", "error"),
    "lookup-unavailable": ("status", "stage", "repaired", "failed_file", "still-unparseable", "pending", "duplicates", "error"),
    "apply-unavailable": ("status", "stage", "repaired", "still-unparseable", "pending", "duplicates", "error"),
    "apply-incomplete": ("status", "stage", "still-unparseable", "repaired", "completed_operations", "pending_operations",
                         "residual_index_keys", "duplicates", "automatic_rerun_recovery", "error"),
    "completed": ("status", "scanned", "excluded-path", "repaired", "still-unparseable", "pending", "residual_synthetic_index_keys",
                  "index_file_mismatches", "duplicates quarantined this run", "duplicates awaiting manual review"),
}

# (name, title prefix of the section it must sit in, literal fragment). Closed list; the fragments are the clauses the
# 2026-10-20 review of #437 called out, plus the stop rules added since.
ANCHORS = (
    ("preflight failure is not a content failure", "Step 0.5:", "不得把整批記入 `still-unparseable`"),
    ("lookup tool failure is not a content failure", "Step 2:", "兩者不可混用"),
    ("recipe output is final, no manual derivation", "Step 2:", "不退回手動推導"),
    ("shared old key is split safely", "P1:", "舊 synthetic key 的安全分割"),
    ("ignorable differences are a closed list of eight", "P2:", "表只有這 8 項，不得依性質相似類推第 9 項"),
    ("an unverifiable pair fails closed", "P2:", "fail-closed"),
    ("no answer is no authorisation", "P3:", "沒有得到回答（含無人值守）視為沒有授權"),
    ("a non-synthetic holder is always kept", "P4:", "持有者恆為保留檔"),
    ("the final applicable set is recomputed", "P5:", "最終可套用集合"),
    ("re-read and write have nothing between them", "Step 3:", "最後一次重讀與 Write 之間只做記憶體內比對"),
    ("an incomplete apply never recovers by itself", "Step 4:", "automatic_rerun_recovery: false"),
    ("never match loosely", "鐵律", "絕不寬鬆匹配"),
    ("never delete a file", "鐵律", "絕不刪檔"),
)

RECIPE_MARKERS = ("archive-mail-repair-date-recipe", "archive-mail-repair-message-id-recipe", "archive-mail-repair-plan-recipe")


def headings(text):
    """(level, title, line index) of every markdown heading outside fenced blocks."""
    found, fenced = [], False
    for index, line in enumerate(text.splitlines()):
        if line.startswith("```"):
            fenced = not fenced
        elif not fenced:
            match = re.match(r"(#{1,6}) (.*)", line)
            if match:
                found.append((len(match.group(1)), match.group(2), index))
    return found


def section_bounds(text, title_prefix):
    """(first line, last line + 1) of the first section whose heading title starts with `title_prefix`, or None."""
    found = headings(text)
    for position, (level, title, start) in enumerate(found):
        if title.startswith(title_prefix):
            end = next((line for deeper, _, line in found[position + 1:] if deeper <= level), len(text.splitlines()))
            return start, end
    return None


def section_text(text, title_prefix):
    bounds = section_bounds(text, title_prefix)
    return None if bounds is None else "\n".join(text.splitlines()[bounds[0]:bounds[1]])


def template_blocks(text):
    """{status word: block} for every fenced block that opens a report with a `status:` line."""
    found = {}
    for block in fenced_blocks(text):
        match = re.search(r"^status: ([a-z]+(?:-[a-z]+)*)", block, re.M)
        if match is not None:
            found.setdefault(match.group(1), []).append(block)
    return found


def check_code_tables(text):
    problems = []
    try:
        block, outside = split_codes_block(text)
    except AssertionError as error:
        return [str(error)]
    status_heading, status = table_rows(block, "#### status")
    reason_heading, reasons = table_rows(block, "#### still-unparseable")
    for heading, rows in ((status_heading, status), (reason_heading, reasons)):
        count = re.search(r"只有這 (\d+) 類", heading)
        if "不得依性質相似類推" not in heading or count is None or int(count.group(1)) != len(rows):
            problems.append(f"table heading is not a closed count of its rows: {heading}")
        if len(rows) != len(set(rows)):
            problems.append(f"duplicate row in a table: {heading}")
    for word in sorted(set(status) & set(reasons)):
        problems.append(f"{word} is in both tables")
    used_status = set(re.findall(r"\bstatus: ([a-z]+(?:-[a-z]+)*)", outside))
    used_reason = set(re.findall(r"still-unparseable: ([a-z]+(?:-[a-z]+)+)", outside))
    problems += [f"status word outside the table: {word}" for word in sorted(used_status - set(status))]
    problems += [f"reason code outside the table: {word}" for word in sorted(used_reason - set(reasons))]
    for word in status + reasons:
        if re.search(rf"(?<![a-z-]){re.escape(word)}(?![a-z-])", outside) is None:
            problems.append(f"table word never used outside the table: {word}")
    return problems


def check_report_templates(text):
    problems = []
    found = template_blocks(text)
    for status, required in REQUIRED_FIELDS.items():
        blocks = found.get(status, [])
        if len(blocks) != 1:
            problems.append(f"report template for status {status}: expected exactly one, found {len(blocks)}")
            continue
        fields = set(re.findall(r"^([a-z][a-z0-9_ -]*):", blocks[0], re.M))
        for field in required:
            if field not in fields:
                problems.append(f"report template {status} lacks the field {field}")
    for status in found:
        if status not in REQUIRED_FIELDS:
            problems.append(f"report template for a status the frozen table does not know: {status}")
    return problems


def check_preflight(text):
    problems = []
    if text.count(PROBE) != 1:
        problems.append(f"the capability probe call must appear exactly once, found {text.count(PROBE)}")
    first = text.find("search_emails(")
    if first >= 0 and text[first:first + len(PROBE)] != PROBE:
        problems.append("the first search_emails( call in the document is not the capability probe")
    levels = [(title, index) for level, title, index in headings(text) if level == 3]
    order = [next((index for title, index in levels if title.startswith(prefix)), None) for prefix in ("Step 0:", "Step 0.5:", "Step 1:")]
    if None in order or order != sorted(order):
        problems.append("Step 0.5 must exist and sit between Step 0 and Step 1")
    preflight = section_text(text, "Step 0.5:") or ""
    stops = [block for block in template_blocks(text).get("environment-unavailable", []) if "stage: capability-preflight" in block]
    if not stops or not all(block in preflight for block in stops):
        problems.append("the environment-unavailable report with stage: capability-preflight must sit inside Step 0.5")
    return problems


def check_clause_anchors(text):
    problems = []
    for name, prefix, fragment in ANCHORS:
        section = section_text(text, prefix)
        if section is None:
            problems.append(f"{name}: no section starts with {prefix!r}")
        elif fragment not in section:
            problems.append(f"{name}: {fragment!r} is not in the section {prefix!r}")
    return problems


def check_recipe_blocks(text):
    problems = []
    try:
        codes_block, _ = split_codes_block(text)
        reasons = set(table_rows(codes_block, "#### still-unparseable")[1])
    except AssertionError:
        reasons = set()   # check_code_tables reports the missing markers
    for marker in RECIPE_MARKERS:
        start, end = f"<!-- {marker}:start -->", f"<!-- {marker}:end -->"
        if text.count(start) != 1 or text.count(end) != 1 or text.find(start) > text.find(end):
            problems.append(f"{marker}: needs exactly one start marker before exactly one end marker")
            continue
        block = text.split(start, 1)[1].split(end, 1)[0]
        code = re.fullmatch(r"\s*```python\n(.*?)\n```\s*", block, re.S)
        if code is None:
            problems.append(f"{marker}: the block is not a single python fence")
            continue
        try:
            compile(code.group(1), marker, "exec")
        except SyntaxError as error:
            problems.append(f"{marker}: does not compile ({error.msg})")
            continue
        if marker == "archive-mail-repair-message-id-recipe":
            statuses = set(re.findall(r'"status": "([a-z-]+)"', code.group(1))) - {"ok", "unusable"}
            for status in sorted(statuses - {"unique"} - reasons):
                problems.append(f"{marker}: group status {status} is not unique and not in the reason table")
    stage = next((paragraph for paragraph in text.split("\n") if paragraph.startswith("4. **用真 Message-ID")), "")
    if "classify-candidates" not in stage:
        problems.append("stage 4 does not tell the agent to run the Message-ID recipe (classify-candidates)")
    plan = section_text(text, "P1:") or ""
    if "check_index_references" not in plan:
        problems.append("P1 does not point at check_index_references")
    step5 = section_text(text, "Step 5:") or ""
    if "residue-report" not in step5:
        problems.append("Step 5 does not point at residue-report")
    return problems


# The names the shared index loader in archive-mail.md returns (#531), written out by hand on purpose: the parity test
# below compares this set with the loader's code and with what the loader returns when executed.
INDEX_ERRORS = ("emails-not-object", "index-not-object", "index-not-json")
INDEX_GATE_FRAGMENTS = (
    "load_email_index", "archive-mail-index-recipe", "不是本指令的存在檢查", "status: apply-unavailable",
    "stage: index-inspection", "repaired: 0", "index_error:", "still-unparseable: not evaluated",
    # #544 verify: the gate runs before the duplicates/ inventory, so its stop has nothing to report there yet
    # (finding 14), and an empty load is checked against the disk before it is believed (finding 25).
    "`pending: entire target`、`duplicates: not evaluated`", "再確認一次該檔仍存在", "index-missing",
) + INDEX_ERRORS
# Anchors of the three Step 1 paragraphs the gate is ordered against.
INDEX_IDENTITY = "現存 index 若是 symlink"
CANDIDATE_READ = "才讀取 regular files"
INVENTORY = "duplicates/**/*.md"


def check_index_shape_gate(text):
    """#544: Step 1 reads an existing index through the shared loader before any candidate is read, and stops by name.

    Order (verify findings 14 and 26): after the index identity check, before the paragraph that reads the regular files
    and before the duplicates/ inventory. The loader maps a missing file to an empty index, so the gate runs only on an
    index that exists and checks again that it still exists when the load comes back empty (finding 25).
    """
    step1 = section_text(text, "Step 1:")
    if step1 is None:
        return ["no section starts with 'Step 1:'"]
    paragraphs = step1.split("\n\n")

    def first(anchor):
        return next((i for i, p in enumerate(paragraphs) if anchor in p), None)

    gate = first("load_email_index")
    if gate is None:
        return ["Step 1 does not read the index through load_email_index"]
    problems = [f"the load_email_index paragraph lacks {fragment}" for fragment in INDEX_GATE_FRAGMENTS
                if fragment not in paragraphs[gate]]
    identity, reads, inventory = first(INDEX_IDENTITY), first(CANDIDATE_READ), first(INVENTORY)
    if identity is None or not identity < gate:
        problems.append("load_email_index must come after the index identity check")
    if reads is None or inventory is None or not gate < min(reads, inventory):
        problems.append("load_email_index must come before any candidate file is read or the duplicates/ inventory is taken")
    return problems


PINS = {
    "code tables": check_code_tables,
    "report templates": check_report_templates,
    "preflight": check_preflight,
    "clause anchors": check_clause_anchors,
    "recipe blocks": check_recipe_blocks,
    "index shape gate": check_index_shape_gate,
}


def replaced(text, old, new, count=1):
    assert text.count(old) >= 1, f"the mutation target is gone from the SOP: {old[:60]!r}"
    return text.replace(old, new, count)


def drop_line(text, prefix):
    lines = text.split("\n")
    kept = [line for line in lines if not line.startswith(prefix)]
    assert len(kept) < len(lines), f"no line starts with {prefix!r}"
    return "\n".join(kept)


def remove_in_section(text, title_prefix, fragment):
    """Remove every occurrence of `fragment` from the section (an anchor holds as long as one is left)."""
    start, end = section_bounds(text, title_prefix)
    lines = text.split("\n")
    section = "\n".join(lines[start:end])
    assert fragment in section, f"{fragment!r} is not in {title_prefix!r}"
    return "\n".join(lines[:start] + [section.replace(fragment, "")] + lines[end:])


def move_fragment(text, title_prefix, fragment, into_prefix):
    removed = remove_in_section(text, title_prefix, fragment)
    start, _ = section_bounds(removed, into_prefix)
    lines = removed.split("\n")
    return "\n".join(lines[:start + 1] + [fragment] + lines[start + 1:])


def move_index_gate(text, anchor, after):
    """Move Step 1's load_email_index paragraph to just after (or just before) the paragraph holding `anchor`."""
    start, end = section_bounds(text, "Step 1:")
    lines = text.split("\n")
    paragraphs = "\n".join(lines[start:end]).split("\n\n")
    gate = next(i for i, p in enumerate(paragraphs) if "load_email_index" in p)
    rest = [p for i, p in enumerate(paragraphs) if i != gate]
    target = next(i for i, p in enumerate(rest) if anchor in p) + (1 if after else 0)
    moved = rest[:target] + [paragraphs[gate]] + rest[target:]
    assert moved != paragraphs, "the mutation changed nothing"
    return "\n".join(lines[:start] + "\n\n".join(moved).split("\n") + lines[end:])


def swap_sections(text, first_prefix, second_prefix):
    lines = text.split("\n")
    (a0, a1), (b0, b1) = section_bounds(text, first_prefix), section_bounds(text, second_prefix)
    assert a1 == b0, "the two sections must be neighbours"
    return "\n".join(lines[:a0] + lines[b0:b1] + lines[a0:a1] + lines[b1:])


class SopPinsOnTheShippedText(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = sop_text()

    def test_every_pin_is_clean_on_the_shipped_sop(self):
        for name, check in PINS.items():
            with self.subTest(pin=name):
                self.assertEqual(check(self.text), [])

    def test_the_anchor_list_names_each_fragment_once_and_every_section_it_uses_exists(self):
        names = [name for name, _, _ in ANCHORS]
        self.assertEqual(len(names), len(set(names)))
        for name, prefix, fragment in ANCHORS:
            with self.subTest(anchor=name):
                self.assertIsNotNone(section_bounds(self.text, prefix))
                self.assertIn(fragment, section_text(self.text, prefix))

    def test_headings_inside_code_fences_are_not_sections(self):
        titles = [title for _, title, _ in headings(self.text)]
        self.assertFalse([t for t in titles if t.startswith("Foundation")], "a python comment was read as a heading")


class SopPinsCatchNamedChanges(unittest.TestCase):
    """Each entry: (pin, what changes, how the text changes, a word the pin's problem list must contain)."""

    @classmethod
    def setUpClass(cls):
        cls.text = sop_text()
        cls.mutations = [
            ("code tables", "a status word follows still-unparseable:", lambda t: replaced(t, "still-unparseable: <停止前已具名判定的檔案 basename 與原因碼；未評估者不列入此欄>", "still-unparseable: environment-unavailable"), "environment-unavailable"),
            ("code tables", "a reason code outside the table", lambda t: replaced(t, "記 `still-unparseable: subject-unavailable`，不發空查詢", "記 `still-unparseable: other-failure`，不發空查詢"), "other-failure"),
            ("code tables", "the closed count disagrees with the rows", lambda t: replaced(t, "只有這 19 類", "只有這 20 類"), "closed count"),
            ("code tables", "the closing phrase is removed from a heading", lambda t: replaced(t, "（只有這 6 類，不得依性質相似類推）", "（只有這 6 類）"), "closed count"),
            ("code tables", "a row is added to the status table for a word nothing uses", lambda t: replaced(t, "| `apply-incomplete` | Step 2.5、Step 3、Step 4 |", "| `never-used-state` | Step 9 | x | y |\n| `apply-incomplete` | Step 2.5、Step 3、Step 4 |"), "never-used-state"),
            ("code tables", "a word sits in both tables", lambda t: replaced(t, "| `subject-unavailable` | Step 2 階段 1 |", "| `completed` | Step 2 階段 1 |\n| `subject-unavailable` | Step 2 階段 1 |"), "both tables"),
            ("code tables", "the table markers are removed", lambda t: replaced(t, "<!-- archive-mail-repair-codes:start -->", ""), "exactly one"),
            ("report templates", "duplicates is dropped from the apply-incomplete report", lambda t: drop_line(t, "duplicates: before <N> / after <M>（已搬移"), "apply-incomplete lacks the field duplicates"),
            ("report templates", "failed_file is renamed in the lookup report", lambda t: replaced(t, "failed_file: <本次失敗的檔案 basename>", "failed: <本次失敗的檔案 basename>"), "failed_file"),
            ("report templates", "index_file_mismatches is dropped from the final report", lambda t: drop_line(t, "index_file_mismatches:"), "index_file_mismatches"),
            ("report templates", "automatic_rerun_recovery is dropped from the apply-incomplete report", lambda t: drop_line(t, "automatic_rerun_recovery:"), "automatic_rerun_recovery"),
            ("report templates", "the lookup report loses its status line", lambda t: replaced(t, "\nstatus: lookup-unavailable\nstage: rekey-lookup", "\nstate: lookup-unavailable\nstage: rekey-lookup"), "lookup-unavailable"),
            ("report templates", "the preflight report loses its error field", lambda t: drop_line(t, "error: <錯誤類別與說明；沒有有效 envelope"), "environment-unavailable lacks the field error"),
            ("report templates", "a sixth template appears", lambda t: replaced(t, "### 停止報告的 duplicates 欄位", "```text\nstatus: surprise-state\nrepaired: 0\n```\n\n### 停止報告的 duplicates 欄位"), "surprise-state"),
            ("preflight", "the probe call is deleted", lambda t: replaced(t, PROBE, ""), "probe call must appear exactly once"),
            ("preflight", "another search_emails( call comes first", lambda t: replaced(t, "## 用法", "先呼叫 search_emails(field: \"sender\") 看看。\n\n## 用法"), "first search_emails"),
            ("preflight", "Step 0.5 and Step 1 swap places", lambda t: swap_sections(t, "Step 0.5:", "Step 1:"), "between Step 0 and Step 1"),
            ("preflight", "the Step 0.5 heading is renamed", lambda t: replaced(t, "### Step 0.5: SQLite", "### Step 0.6: SQLite"), "between Step 0 and Step 1"),
            ("preflight", "the preflight report loses its stage", lambda t: drop_line(t, "stage: capability-preflight"), "capability-preflight"),
            ("recipe blocks", "an end marker is removed", lambda t: replaced(t, "<!-- archive-mail-repair-message-id-recipe:end -->", ""), "message-id-recipe: needs exactly one"),
            ("recipe blocks", "a start marker is duplicated", lambda t: replaced(t, "<!-- archive-mail-repair-plan-recipe:start -->", "<!-- archive-mail-repair-plan-recipe:start -->\n<!-- archive-mail-repair-plan-recipe:start -->"), "plan-recipe: needs exactly one"),
            ("recipe blocks", "a recipe stops compiling", lambda t: replaced(t, "def _unusable(reason):", "def _unusable(reason)"), "does not compile"),
            ("recipe blocks", "the recipe invents a group status", lambda t: replaced(t, '{"status": "message-id-format-collision", "candidates": answers}', '{"status": "ambiguous", "candidates": answers}'), "ambiguous"),
            ("recipe blocks", "stage 4 stops mentioning the recipe", lambda t: replaced(t, "以下方 Message-ID recipe 的 `classify-candidates` 計算", "以下方 Message-ID recipe 計算"), "stage 4"),
            ("recipe blocks", "P1 stops pointing at its recipe function", lambda t: remove_in_section(t, "P1:", "第 4、5 項由下方計畫 recipe 的 `check_index_references` 執行，不靠逐項心算。"), "check_index_references"),
            ("index shape gate", "the loader paragraph moves after the candidate read", lambda t: move_index_gate(t, CANDIDATE_READ, after=True), "must come before any candidate file is read"),
            ("index shape gate", "the loader paragraph moves after the duplicates/ inventory", lambda t: move_index_gate(t, INVENTORY, after=True), "must come before any candidate file is read"),
            ("index shape gate", "the loader paragraph moves in front of the identity check", lambda t: move_index_gate(t, INDEX_IDENTITY, after=False), "must come after the index identity check"),
            ("index shape gate", "an empty load is no longer checked against the disk", lambda t: remove_in_section(t, "Step 1:", "，再確認一次該檔仍存在"), "仍存在"),
            ("index shape gate", "the loader is no longer named", lambda t: replaced(t, "load_email_index", "the index loader", count=-1), "does not read the index through load_email_index"),
            ("index shape gate", "the stop loses its stage", lambda t: remove_in_section(t, "Step 1:", "`stage: index-inspection`、"), "stage: index-inspection"),
            ("index shape gate", "one of the loader's names is dropped", lambda t: remove_in_section(t, "Step 1:", " | index-not-json"), "index-not-json"),
            ("index shape gate", "the stop reports the inventory it has not taken yet", lambda t: replaced(t, "`pending: entire target`、`duplicates: not evaluated`（`duplicates/` 還沒盤點）", "`pending: entire target`，`duplicates:` 依上述盤點結果填"), "duplicates: not evaluated"),
            ("index shape gate", "the loader is no longer said to differ from the existence check", lambda t: remove_in_section(t, "Step 1:", "不是本指令的存在檢查"), "不是本指令的存在檢查"),
        ]
        for name, prefix, fragment in ANCHORS:
            cls.mutations.append(("clause anchors", f"{name}: the fragment is deleted",
                                  lambda t, p=prefix, f=fragment: remove_in_section(t, p, f), name))
            cls.mutations.append(("clause anchors", f"{name}: the fragment moves to the background section",
                                  lambda t, p=prefix, f=fragment: move_fragment(t, p, f, "背景"), name))

    def test_each_named_change_is_reported_by_its_pin(self):
        self.assertGreaterEqual(len(self.mutations), 50)
        for pin, change, mutate, expected in self.mutations:
            with self.subTest(pin=pin, change=change):
                mutated = mutate(self.text)
                self.assertNotEqual(mutated, self.text, "the mutation changed nothing")
                problems = PINS[pin](mutated)
                self.assertTrue(any(expected in problem for problem in problems),
                                f"{pin} did not report {expected!r}; it said {problems}")

    def test_a_change_to_one_pin_does_not_raise_another_pins_alarm_by_accident(self):
        mutated = drop_line(self.text, "stage: capability-preflight")
        for name in ("code tables", "clause anchors", "recipe blocks"):
            with self.subTest(pin=name):
                self.assertEqual(PINS[name](mutated), [])


class IndexMissingDuplicatesTests(unittest.TestCase):
    """#544 verify round 2 (findings 10, 38): the closed duplicates table lists a value for both index-missing stops.

    An index that never existed stops after the duplicates/ inventory (its value comes from the inventory); one that
    disappears after the identity check stops before it (not evaluated). Both are `file-inspection` stops.
    """

    @classmethod
    def setUpClass(cls):
        rows = [line for line in sop_text().split("\n") if line.startswith("| `")]
        cls.not_evaluated = next(line for line in rows if line.startswith("| `not evaluated` |"))
        cls.before_after = next(line for line in rows if line.startswith("| `before N / after N` |"))

    def test_the_stop_after_the_inventory_is_listed_under_before_and_after(self):
        self.assertIn("`index-missing`", self.before_after)
        self.assertIn("file-inspection", self.before_after)

    def test_the_stop_before_the_inventory_is_listed_under_not_evaluated(self):
        self.assertIn("`index-missing`", self.not_evaluated)
        self.assertIn("file-inspection", self.not_evaluated)


ARCHIVE_MAIL = DOCUMENT.parent / "archive-mail.md"
INDEX_RECIPE = ("<!-- archive-mail-index-recipe:start -->", "<!-- archive-mail-index-recipe:end -->")


def index_loader_code():
    text = ARCHIVE_MAIL.read_text()
    for marker in INDEX_RECIPE:
        if text.count(marker) != 1:
            raise AssertionError(f"archive-mail.md must carry exactly one {marker}")
    block = text.split(INDEX_RECIPE[0], 1)[1].split(INDEX_RECIPE[1], 1)[0]
    code = re.fullmatch(r"\s*```python\n(.*?)\n```\s*", block, re.S)
    if code is None:
        raise AssertionError("the archive-mail index recipe is not exactly one python fence")
    return code.group(1)


class IndexLoaderParityTests(unittest.TestCase):
    """#544: the repair command stops with the shared loader's names, so the two commands cannot drift apart."""

    @classmethod
    def setUpClass(cls):
        cls.code = index_loader_code()
        namespace = {"__name__": "archive_mail_index_recipe"}
        exec(compile(cls.code, str(ARCHIVE_MAIL) + ":index", "exec"), namespace)
        cls.load = staticmethod(namespace["load_email_index"])

    def test_the_shared_loader_returns_exactly_the_three_names(self):
        self.assertEqual(set(re.findall(r'return None, "([a-z-]+)"', self.code)), set(INDEX_ERRORS))

    def test_step_1_names_exactly_what_the_shared_loader_returns(self):
        step1 = section_text(sop_text(), "Step 1:")
        written = set(re.findall(r"(?<![a-z-])(?:emails|index)-not-[a-z]+(?![a-z-])", step1))
        self.assertEqual(written, set(re.findall(r'return None, "([a-z-]+)"', self.code)))

    def test_the_executed_loader_answers_the_shapes_the_stop_is_for(self):
        cases = (
            ('{"emails": null}', (None, "emails-not-object")),
            ('{"emails": []}', (None, "emails-not-object")),
            ("[]", (None, "index-not-object")),
            ("", (None, "index-not-json")),
            ("{}", ({}, None)),   # D3: an index with no entries, not a stop
        )
        with tempfile.TemporaryDirectory() as directory:
            for content, expected in cases:
                with self.subTest(content=content):
                    path = Path(directory) / "email_index.json"
                    path.write_text(content)
                    self.assertEqual(self.load(str(path)), expected)

    def test_a_missing_file_reads_as_an_empty_index_which_is_why_an_empty_load_is_rechecked(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.load(str(Path(directory) / "absent.json")), ({}, None))


if __name__ == "__main__":
    unittest.main()
