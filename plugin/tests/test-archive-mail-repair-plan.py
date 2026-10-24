#!/usr/bin/env python3
"""Execute the repair SOP's plan recipe (#526), rather than a second implementation.

The recipe blocks live in plugin/commands/archive-mail-repair-synthetic-ids.md between
`<!-- archive-mail-repair-plan-recipe:start/end -->`. Fixtures use example.invalid addresses only.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


COMMANDS = Path(__file__).resolve().parents[1] / "commands"
SOP = COMMANDS / "archive-mail-repair-synthetic-ids.md"
ARCHIVE = COMMANDS / "archive-mail.md"


def recipe_code(document, marker):
    text = document.read_text()
    block = text.split(f"<!-- {marker}:start -->", 1)[1]
    block = block.split(f"<!-- {marker}:end -->", 1)[0]
    return re.fullmatch(r"\s*```python\n(.*?)\n```\s*", block, re.S).group(1)


def load(*sources):
    """Execute recipe blocks, in the order given, in one namespace (as the SOP tells the agent to paste them)."""
    namespace = {"__name__": "archive_recipe"}
    for document, marker in sources:
        exec(compile(recipe_code(document, marker), f"{document}:{marker}", "exec"), namespace)
    return namespace


def file_entry(name):
    return {"file": name, "date": "2026-01-01T00:00:00Z", "subject": "s", "thread_key": "t"}


TRUE_KEY = "<real@example.invalid>"


class IndexReferenceCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.recipe = load((SOP, "archive-mail-repair-plan-recipe"))
        cls.check = staticmethod(cls.recipe["check_index_references"])

    def test_s0_two_copies_one_with_a_legitimate_entry_pass_and_the_holder_is_kept(self):
        scanned = [{"file": "kept.md", "message_id": TRUE_KEY}, {"file": "dup.md", "message_id": "synthetic:one"}]
        index = {TRUE_KEY: file_entry("kept.md"), "synthetic:one": file_entry("dup.md")}
        result = self.check(index, scanned, [{"key": TRUE_KEY, "files": ["dup.md"]}])
        self.assertEqual(result["rejections"], [])
        self.assertEqual(result["groups"], [
            {"key": TRUE_KEY, "files": ["dup.md"], "holders": ["kept.md"], "retained": "kept.md"}])

    def test_s1_an_orphan_synthetic_entry_pointing_at_a_planned_file_rejects_the_whole_group(self):
        # No scanned file carries synthetic:three, yet the index sends it to b.md, which the plan would quarantine.
        scanned = [{"file": "a.md", "message_id": "synthetic:one"}, {"file": "b.md", "message_id": "synthetic:two"}]
        index = {"synthetic:one": file_entry("a.md"), "synthetic:two": file_entry("b.md"),
                 "synthetic:three": file_entry("b.md")}
        result = self.check(index, scanned, [{"key": TRUE_KEY, "files": ["a.md", "b.md"]}])
        self.assertEqual(result["groups"], [])
        self.assertEqual(result["rejections"], [{
            "files": ["a.md", "b.md"], "code": "index-reference-conflict",
            "entries": [{"key": "synthetic:three", "file": "b.md"}]}])

    def test_s2_a_non_synthetic_entry_pointing_at_a_file_that_will_be_rewritten_rejects_the_group(self):
        scanned = [{"file": "a.md", "message_id": "synthetic:one"}]
        index = {"synthetic:one": file_entry("a.md"), "<other@example.invalid>": file_entry("a.md")}
        result = self.check(index, scanned, [{"key": TRUE_KEY, "files": ["a.md"]}])
        self.assertEqual(result["rejections"], [{
            "files": ["a.md"], "code": "index-reference-conflict",
            "entries": [{"key": "<other@example.invalid>", "file": "a.md"}]}])

    def test_an_entry_under_the_groups_own_new_key_is_allowed_to_point_at_a_planned_file(self):
        scanned = [{"file": "a.md", "message_id": "synthetic:one"}]
        index = {"synthetic:one": file_entry("a.md"), TRUE_KEY: file_entry("a.md")}
        result = self.check(index, scanned, [{"key": TRUE_KEY, "files": ["a.md"]}])
        self.assertEqual(result["rejections"], [])

    def test_a_stray_entry_pointing_at_the_retained_holder_is_also_a_conflict(self):
        scanned = [{"file": "kept.md", "message_id": TRUE_KEY}, {"file": "dup.md", "message_id": "synthetic:one"}]
        index = {TRUE_KEY: file_entry("kept.md"), "<stray@example.invalid>": file_entry("kept.md"),
                 "synthetic:one": file_entry("dup.md")}
        result = self.check(index, scanned, [{"key": TRUE_KEY, "files": ["dup.md"]}])
        self.assertEqual([r["code"] for r in result["rejections"]], ["index-reference-conflict"])
        self.assertEqual(result["rejections"][0]["files"], ["dup.md", "kept.md"])

    def test_s3_a_top_level_file_already_holding_the_true_id_joins_the_group_even_without_an_index_entry(self):
        scanned = [{"file": "a.md", "message_id": TRUE_KEY}, {"file": "c.md", "message_id": "synthetic:one"}]
        index = {"synthetic:one": file_entry("c.md")}   # a.md is not in the index at all
        result = self.check(index, scanned, [{"key": TRUE_KEY, "files": ["c.md"]}])
        self.assertEqual(result["rejections"], [])
        self.assertEqual(result["groups"][0]["holders"], ["a.md"])
        self.assertEqual(result["groups"][0]["retained"], "a.md")

    def test_s3_two_non_synthetic_holders_of_one_true_id_make_the_group_unverifiable(self):
        scanned = [{"file": "a1.md", "message_id": TRUE_KEY}, {"file": "a2.md", "message_id": TRUE_KEY},
                   {"file": "c.md", "message_id": "synthetic:one"}]
        result = self.check({"synthetic:one": file_entry("c.md")}, scanned,
                            [{"key": TRUE_KEY, "files": ["c.md"]}])
        self.assertEqual(result["groups"], [])
        self.assertEqual(result["rejections"], [
            {"files": ["c.md", "a1.md", "a2.md"], "code": "duplicate-unverifiable", "entries": []}])

    def test_a_holder_that_spells_the_same_id_differently_is_a_spelling_mismatch_not_a_second_spelling(self):
        scanned = [{"file": "a.md", "message_id": "real@example.invalid"},
                   {"file": "c.md", "message_id": "synthetic:one"}]
        result = self.check({"synthetic:one": file_entry("c.md")}, scanned,
                            [{"key": TRUE_KEY, "files": ["c.md"]}])
        self.assertEqual([r["code"] for r in result["rejections"]], ["existing-key-spelling-mismatch"])
        self.assertEqual(result["rejections"][0]["files"], ["c.md", "a.md"])

    def test_one_rejected_group_does_not_reject_an_unrelated_group(self):
        scanned = [{"file": "a.md", "message_id": "synthetic:one"}, {"file": "b.md", "message_id": "synthetic:two"}]
        index = {"synthetic:one": file_entry("a.md"), "synthetic:two": file_entry("b.md"),
                 "synthetic:orphan": file_entry("b.md")}
        result = self.check(index, scanned, [{"key": TRUE_KEY, "files": ["a.md"]},
                                             {"key": "<second@example.invalid>", "files": ["b.md"]}])
        self.assertEqual([g["key"] for g in result["groups"]], [TRUE_KEY])
        self.assertEqual([r["files"] for r in result["rejections"]], [["b.md"]])

    def test_malformed_plans_fail_loudly_instead_of_being_accepted(self):
        scanned = [{"file": "a.md", "message_id": TRUE_KEY}]
        with self.assertRaises(ValueError):   # a planned file that is not a synthetic scanned file
            self.check({}, scanned, [{"key": "<x@example.invalid>", "files": ["a.md"]}])
        with self.assertRaises(ValueError):   # a synthetic string used as the new key
            self.check({}, [{"file": "a.md", "message_id": "synthetic:one"}],
                       [{"key": "synthetic:two", "files": ["a.md"]}])
        with self.assertRaises(ValueError):   # one file in two groups
            self.check({}, [{"file": "a.md", "message_id": "synthetic:one"}],
                       [{"key": "<x@example.invalid>", "files": ["a.md"]},
                        {"key": "<y@example.invalid>", "files": ["a.md"]}])


class ResidueReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = staticmethod(load((SOP, "archive-mail-repair-plan-recipe"))["residue_report"])

    def test_s0_a_clean_run_is_completed_with_both_fields_empty(self):
        result = self.report({TRUE_KEY: file_entry("kept.md")},
                             [{"file": "kept.md", "message_id": TRUE_KEY}], ["dup.md", "kept.md"])
        self.assertEqual(result, {"residual_synthetic_index_keys": [], "index_file_mismatches": [],
                                  "status": "completed"})

    def test_a_remaining_synthetic_key_makes_the_status_completed_with_residue(self):
        result = self.report({"synthetic:left": file_entry("left.md")}, [], [])
        self.assertEqual(result["status"], "completed-with-residue")
        self.assertEqual(result["residual_synthetic_index_keys"], [{"key": "synthetic:left", "file": "left.md"}])

    def test_rerun_after_apply_incomplete_is_not_completed(self):
        # The frontmatter already holds the true id, the index still maps the old key to the file, and Step 1 saw
        # no synthetic file at all.
        result = self.report({"synthetic:old": file_entry("fixed.md")},
                             [{"file": "fixed.md", "message_id": TRUE_KEY}], [])
        self.assertEqual(result["status"], "completed-with-residue")
        self.assertEqual(result["residual_synthetic_index_keys"], [{"key": "synthetic:old", "file": "fixed.md"}])

    def test_a_touched_file_whose_entry_key_differs_from_its_message_id_is_a_mismatch(self):
        result = self.report({"<wrong@example.invalid>": file_entry("kept.md")},
                             [{"file": "kept.md", "message_id": TRUE_KEY}], ["kept.md"])
        self.assertEqual(result["index_file_mismatches"],
                         [{"file": "kept.md", "kind": "key-differs-from-file-message-id"}])
        self.assertEqual(result["status"], "completed-with-residue")

    def test_an_entry_pointing_at_a_touched_file_that_left_the_top_level_is_a_mismatch(self):
        result = self.report({TRUE_KEY: file_entry("moved.md")}, [], ["moved.md"])
        self.assertEqual(result["index_file_mismatches"],
                         [{"file": "moved.md", "kind": "file-not-in-target-top-level"}])
        self.assertEqual(result["status"], "completed-with-residue")

    def test_drift_unrelated_to_this_run_does_not_change_the_status(self):
        # Decision 5: only files touched this run are examined for key/file drift.
        result = self.report({"<old@example.invalid>": file_entry("untouched.md")},
                             [{"file": "untouched.md", "message_id": "<different@example.invalid>"}], ["other.md"])
        self.assertEqual(result["index_file_mismatches"], [])
        self.assertEqual(result["status"], "completed")


class DateCoreTests(unittest.TestCase):
    """parse_zone_argument and resolve_instant: the one place a user-given zone turns a naive date into an instant."""

    @classmethod
    def setUpClass(cls):
        from zoneinfo import available_timezones
        if not available_timezones():
            raise AssertionError("no tz database on this machine: parse_zone_argument cannot be tested, "
                                 "and the command would refuse every IANA zone name")
        # Same order the SOP tells the agent to paste: the archive-mail date recipe first, then this block.
        cls.recipe = load((ARCHIVE, "archive-mail-date-recipe"), (SOP, "archive-mail-repair-date-recipe"))
        cls.zone = staticmethod(cls.recipe["parse_zone_argument"])
        cls.parse = staticmethod(cls.recipe["parse_archive_date"])
        cls.resolve = staticmethod(cls.recipe["resolve_instant"])

    def resolve_text(self, value, zone_text=None):
        zone = None if zone_text is None else self.zone(zone_text)
        if zone_text is not None:
            self.assertIsNotNone(zone, zone_text)
        return self.resolve(self.parse(value), zone)

    def test_zone_argument_accepts_iana_names_and_fixed_offsets(self):
        for text in ["Asia/Taipei", "UTC", "+08:00", "-05:30", "America/New_York"]:
            with self.subTest(text=text):
                self.assertIsNotNone(self.zone(text))

    def test_zone_argument_refuses_everything_else(self):
        for text in ["CST", "JST", "Taipei", "asia/taipei", "", " Asia/Taipei", "Asia/Taipei ", "../etc/localtime",
                     "+8", "+0800", "+25:00", "+08:60", "-00:00", "EST", "GMT", "+08:00:00", None, 8, ["+08:00"]]:
            with self.subTest(text=text):
                self.assertIsNone(self.zone(text))

    def test_the_319_example_becomes_the_same_instant_as_its_utc_twin(self):
        verdict, instant, basis = self.resolve_text("2026-05-29T20:24:53", "Asia/Taipei")
        self.assertEqual((verdict, basis), ("ok", "zone-assumed"))
        self.assertEqual(instant.isoformat(), "2026-05-29T12:24:53+00:00")
        twin = self.resolve_text("2026-05-29T12:24:53Z")
        self.assertEqual(twin[0], "ok")
        self.assertEqual(instant, twin[1])

    def test_a_fixed_offset_zone_converts_the_same_way(self):
        verdict, instant, basis = self.resolve_text("2026-05-29T20:24:53", "+08:00")
        self.assertEqual((verdict, instant.isoformat(), basis), ("ok", "2026-05-29T12:24:53+00:00", "zone-assumed"))

    def test_an_explicit_offset_is_never_touched_by_the_zone(self):
        for zone in [None, "Asia/Taipei", "-05:30"]:
            with self.subTest(zone=zone):
                verdict, instant, basis = self.resolve_text("2026-05-29T20:24:53+08:00", zone)
                self.assertEqual((verdict, instant.isoformat(), basis), ("ok", "2026-05-29T12:24:53+00:00", "explicit"))
        self.assertEqual(self.resolve_text("Fri, 29 May 2026 20:24:53 +0800", "-05:30")[2], "explicit")

    def test_a_naive_date_without_a_zone_is_never_guessed(self):
        for value in ["2026-05-29T20:24:53", "2026-05-29 20:24:53", "2026-05-29T20:24:53-00:00",
                      "Fri, 29 May 2026 20:24:53 -0000"]:
            with self.subTest(value=value):
                self.assertEqual(self.resolve_text(value), ("date-offset-missing", None, None))

    def test_the_unknown_offset_marker_is_treated_as_naive_when_a_zone_is_given(self):
        verdict, instant, basis = self.resolve_text("Fri, 29 May 2026 20:24:53 -0000", "Asia/Taipei")
        self.assertEqual((verdict, instant.isoformat(), basis), ("ok", "2026-05-29T12:24:53+00:00", "zone-assumed"))

    def test_dates_without_a_usable_time_stay_unparseable_whatever_the_zone(self):
        for value in ["2026-05-29", "Fri, 29 May 2026", "not a date", "", None, 20260529]:
            with self.subTest(value=value):
                self.assertEqual(self.resolve(self.parse(value), self.zone("Asia/Taipei")),
                                 ("date-unparseable", None, None))

    def test_a_local_time_that_does_not_exist_or_exists_twice_is_ambiguous(self):
        for value in ["2026-03-08T02:30:00", "2026-11-01T01:30:00"]:   # spring-forward gap, fall-back overlap
            with self.subTest(value=value):
                self.assertEqual(self.resolve_text(value, "America/New_York"),
                                 ("date-ambiguous-local-time", None, None))
        self.assertEqual(self.resolve_text("2026-06-01T12:00:00", "America/New_York")[0], "ok")

    def test_a_fixed_offset_never_reports_an_ambiguous_local_time(self):
        for value in ["2026-03-08T02:30:00", "2026-11-01T01:30:00"]:
            with self.subTest(value=value):
                self.assertEqual(self.resolve_text(value, "-05:00")[0], "ok")

    def test_the_json_adapters_report_the_same_results_as_plain_data(self):
        check, resolve = self.recipe["check_zone_argument"], self.recipe["resolve_dates"]
        self.assertEqual(check("Asia/Taipei"), {"ok": True, "zone": "Asia/Taipei"})
        self.assertEqual(check("+08:00"), {"ok": True, "zone": "+08:00"})
        self.assertEqual(check("CST"), {"ok": False, "zone": None})
        rows = [{"file": "a.md", "date": "2026-05-29T20:24:53"}, {"file": "b.md", "date": "2026-05-29T12:24:53Z"},
                {"file": "c.md", "date": "garbage"}]
        result = resolve("Asia/Taipei", rows)
        self.assertEqual(result["zone"], "Asia/Taipei")
        self.assertEqual(result["rows"], [
            {"file": "a.md", "verdict": "ok", "instant": "2026-05-29T12:24:53+00:00", "basis": "zone-assumed"},
            {"file": "b.md", "verdict": "ok", "instant": "2026-05-29T12:24:53+00:00", "basis": "explicit"},
            {"file": "c.md", "verdict": "date-unparseable", "instant": None, "basis": None}])
        self.assertEqual(resolve(None, rows[:1])["rows"][0]["verdict"], "date-offset-missing")
        with self.assertRaises(ValueError):   # an unusable zone is a usage error, not a quiet "no zone"
            resolve("CST", rows)

    def test_all_recipe_blocks_run_together_through_the_command_line(self):
        with tempfile.TemporaryDirectory() as work, tempfile.TemporaryDirectory() as data:
            script = Path(work) / "repair_recipe.py"
            script.write_text("\n".join(
                recipe_code(document, marker) for document, marker in [
                    (ARCHIVE, "archive-mail-date-recipe"), (SOP, "archive-mail-repair-date-recipe"),
                    (SOP, "archive-mail-repair-plan-recipe")]) + "\n")
            def run(command, payload):
                source, target = Path(data) / "in.json", Path(data) / "out.json"
                source.write_text(json.dumps(payload))
                done = subprocess.run([sys.executable, "-I", str(script), command, str(source), str(target)],
                                      capture_output=True, text=True)
                self.assertEqual(done.returncode, 0, done.stderr)
                return json.loads(target.read_text())
            self.assertEqual(run("check-zone-argument", {"text": "Asia/Taipei"}), {"ok": True, "zone": "Asia/Taipei"})
            result = run("resolve-dates", {"zone": "Asia/Taipei", "rows": [{"file": "a.md", "date": "2026-05-29T20:24:53"}]})
            self.assertEqual(result["rows"][0]["instant"], "2026-05-29T12:24:53+00:00")
            archive = Path(data) / "archive"
            archive.mkdir()
            (archive / "a.md").write_text(make_file(message_id="synthetic:one", date="2026-05-29T20:24:53"))
            (archive / "b.md").write_text(make_file(date="2026-05-29T12:24:53Z"))
            pair = {"a_path": str(archive / "a.md"), "b_path": str(archive / "b.md"), "target": str(archive)}
            self.assertEqual(run("classify-pair", {**pair, "zone": None})["fields"], ["date"])
            self.assertEqual(run("classify-pair", {**pair, "zone": "Asia/Taipei"})["verdict"], "identical")


class ZonePreviewTests(unittest.TestCase):
    """What the user sees before a zone is applied (#528): residuals, neighbours, and the sample that is shown."""

    @classmethod
    def setUpClass(cls):
        cls.recipe = load((ARCHIVE, "archive-mail-date-recipe"), (SOP, "archive-mail-repair-date-recipe"))
        cls.parse = staticmethod(cls.recipe["parse_archive_date"])

    def at(self, text):
        return self.parse(text)

    def test_residual_is_the_absolute_gap_in_whole_seconds(self):
        residual = self.recipe["residual_seconds"]
        assumed = self.at("2026-05-29T12:24:53Z")
        self.assertEqual(residual(assumed, self.at("2026-05-29T12:24:58Z")), 5)
        self.assertEqual(residual(assumed, self.at("2026-05-29T12:24:50Z")), 3)
        self.assertEqual(residual(assumed, assumed), 0)

    def test_neighbours_count_the_same_senders_same_subject_within_the_window_including_the_match(self):
        count, window = self.recipe["neighbour_count"], __import__("datetime").timedelta(days=1)
        assumed = self.at("2026-05-29T12:24:53Z")
        hourly = [self.at(f"2026-05-{day:02d}T{hour:02d}:24:53Z") for day in (28, 29, 30) for hour in range(24)]
        one_off = [self.at("2026-05-29T12:24:55Z")]
        self.assertEqual(count(assumed, one_off, window), 1)
        self.assertEqual(count(assumed, hourly, window), 49)   # +-24h inclusive: both edges and every hour between
        self.assertEqual(count(assumed, [], window), 0)

    def row(self, name, residual, neighbours):
        return {"file": name, "residual_seconds": residual, "neighbours": neighbours}

    def test_the_shown_sample_is_the_largest_residuals_plus_every_flagged_row(self):
        rows = [self.row("e.md", 4, 1), self.row("a.md", 0, 1), self.row("c.md", 9, 1), self.row("b.md", 9, 1),
                self.row("d.md", 1, 3)]
        shown = self.recipe["preview_rows"](rows, 2)
        # b.md and c.md tie at 9 (basename order); d.md has a small residual but is flagged, so it stays in.
        self.assertEqual([r["file"] for r in shown], ["b.md", "c.md", "d.md"])
        self.assertEqual([r["file"] for r in self.recipe["preview_rows"](rows, None)],
                         ["b.md", "c.md", "e.md", "d.md", "a.md"])

    def test_build_preview_reports_counts_statistics_and_flags(self):
        build = self.recipe["build_preview"]
        rows = [
            {"file": "a.md", "date": "2026-05-29T20:24:53", "received": "2026-05-29T12:24:58Z",
             "peers": ["2026-05-29T12:24:58Z"]},
            {"file": "b.md", "date": "2026-05-29T21:00:00", "received": "2026-05-29T13:00:00Z",
             "peers": ["2026-05-29T11:00:00Z", "2026-05-29T12:00:00Z", "2026-05-29T13:00:00Z"]},
            {"file": "c.md", "date": "2026-05-30T08:00:00", "received": "2026-05-30T00:03:00Z", "peers": []},
        ]
        result = build("Asia/Taipei", rows, no_match=2, k=1)
        self.assertEqual((result["zone"], result["applied"], result["no_match"], result["flagged"]),
                         ("Asia/Taipei", 3, 2, 1))
        self.assertEqual(result["residual_seconds"], {"min": 0, "median": 5, "max": 180})
        self.assertEqual([r["file"] for r in result["shown"]], ["c.md", "b.md"])
        self.assertEqual(result["shown"][0]["assumed"], "2026-05-30T00:00:00+00:00")
        self.assertEqual([r["flag"] for r in result["shown"]], [False, True])
        self.assertEqual(build("Asia/Taipei", [], no_match=0)["residual_seconds"], None)

    def test_a_wrong_zone_can_still_find_exactly_one_candidate_and_only_the_flag_and_the_user_stand_in_the_way(self):
        # Known limit (documented in the SOP): an hourly sender matches perfectly in the wrong zone, too.
        hourly = [f"2026-05-29T{hour:02d}:24:53Z" for hour in range(24)]
        row = {"file": "a.md", "date": "2026-05-29T12:24:53", "received": "2026-05-29T12:24:53Z", "peers": hourly}
        result = self.recipe["build_preview"]("+00:00", [row], no_match=0)
        self.assertEqual(result["shown"][0]["residual_seconds"], 0)   # looks perfect
        self.assertTrue(result["shown"][0]["flag"])                   # and is flagged anyway
        self.assertEqual(result["flagged"], 1)

    def test_preview_input_that_is_not_a_zone_assumed_file_fails_loudly(self):
        build = self.recipe["build_preview"]
        explicit = {"file": "a.md", "date": "2026-05-29T12:24:53Z", "received": "2026-05-29T12:24:53Z", "peers": []}
        with self.assertRaises(ValueError):
            build("Asia/Taipei", [explicit])
        naive = dict(explicit, date="2026-05-29T20:24:53")
        with self.assertRaises(ValueError):
            build("CST", [naive])
        with self.assertRaises(ValueError):
            build("Asia/Taipei", [dict(naive, received="2026-05-29T12:24:53")])   # a received time without offset


def make_file(message_id="<same@example.invalid>", thread_key="Topic", in_reply_to='""', date="2026-01-28T08:35:34Z",
              sender="a@example.invalid", direction="received", extra=(), subject="Topic", cc=None,
              date_line="2026-01-28 08:35", body="Hello", newline="\n"):
    """A file in the simple template (frontmatter of the six core fields, then the Subject/From/To/Date header)."""
    front = [f'message_id: "{message_id}"', f'thread_key: "{thread_key}"', f"in_reply_to: {in_reply_to}",
             f"date: {date}", f"sender: {sender}", f"direction: {direction}", *extra]
    header = [f"Subject: {subject}", "From: A <a@example.invalid>", "To: B <b@example.invalid>"]
    if cc is not None:
        header.append(f"Cc: {cc}")
    header.append(f"Date: {date_line}")
    lines = ["---", *front, "---", "", *header, "", body, ""]
    return newline.join(lines)


def make_enriched(summary="- one point", todo="- [ ] one task", archived="2026-02-01", body="Hello", **front):
    simple = make_file(body=body, **front)
    head = simple.split("\n\nSubject:", 1)[0]
    return "\n".join([
        head, "", "# Topic - 2026-01-28 08:35", "", "## 元數據", "", "| 項目 | 內容 |", "|------|------|",
        "| **日期** | 2026-01-28 08:35 |", "", "---", "", "## 信件內容", "", body, "", "---", "", "## 重點摘要", "",
        summary, "", "## 待辦事項", "", todo, "", "---", "", f"*歸檔日期：{archived}*", ""])


SENTINEL = "LEAKCHECK-5f3a9"


class PairClassificationTests(unittest.TestCase):
    """classify_pair: the closed list of differences that still count as one and the same message (#525)."""

    @classmethod
    def setUpClass(cls):
        cls.recipe = load((ARCHIVE, "archive-mail-date-recipe"), (SOP, "archive-mail-repair-date-recipe"),
                          (SOP, "archive-mail-repair-plan-recipe"))
        cls.classify = staticmethod(cls.recipe["classify_pair"])
        cls.zone = staticmethod(cls.recipe["parse_zone_argument"])

    def verdict(self, a, b, zone=None):
        return self.classify(a, b, zone)

    def test_files_that_differ_only_in_message_id_are_identical_with_nothing_ignored(self):
        result = self.verdict(make_file(message_id="synthetic:one"), make_file())
        self.assertEqual(result, {"verdict": "identical", "fields": [], "ignored": []})

    def test_newline_style_alone_is_ignored_as_i1(self):
        result = self.verdict(make_file(newline="\r\n"), make_file())
        self.assertEqual((result["verdict"], result["ignored"]), ("identical", ["I1"]))
        result = self.verdict(make_file(newline="\r"), make_file(newline="\r\n"))
        self.assertEqual((result["verdict"], result["ignored"]), ("identical", ["I1"]))

    def test_the_documented_batch_versus_fallback_differences_are_all_ignored(self):
        fallback = make_file(thread_key="回覆: Re: Topic", sender="A@Example.invalid", direction="sent")
        batch = make_file(extra=("body_type: text",), cc="C <c@example.invalid>")
        result = self.verdict(fallback, batch)
        self.assertEqual(result["verdict"], "identical", result)
        self.assertEqual(result["ignored"], ["I3", "I4", "I5", "I6", "I7"])

    def test_a_date_naming_the_same_instant_in_another_offset_is_i2(self):
        result = self.verdict(make_file(date="2026-01-28T16:35:34+08:00"), make_file(date="2026-01-28T08:35:34Z"))
        self.assertEqual((result["verdict"], result["ignored"]), ("identical", ["I2"]))

    def test_a_naive_date_against_its_utc_twin_needs_the_users_zone(self):
        naive, twin = make_file(date="2026-05-29T20:24:53"), make_file(date="2026-05-29T12:24:53Z")
        result = self.verdict(naive, twin)
        self.assertEqual((result["verdict"], result["fields"]), ("drift", ["date"]))
        result = self.verdict(naive, twin, self.zone("Asia/Taipei"))
        self.assertEqual((result["verdict"], result["ignored"]), ("identical", ["I2"]))
        result = self.verdict(naive, twin, self.zone("UTC"))   # a wrong zone does not make them equal
        self.assertEqual((result["verdict"], result["fields"]), ("drift", ["date"]))

    def test_two_enriched_files_ignore_summary_todos_and_archive_date_as_i8(self):
        a = make_enriched(summary="- alpha", todo="- [ ] first", archived="2026-02-01")
        b = make_enriched(summary="- beta\n- gamma", todo="- [ ] second", archived="2026-03-09")
        result = self.verdict(a, b)
        self.assertEqual((result["verdict"], result["ignored"]), ("identical", ["I8"]), result)

    def test_enriched_files_with_different_mail_content_still_drift(self):
        result = self.verdict(make_enriched(body="Hello"), make_enriched(body="Hullo"))
        self.assertEqual((result["verdict"], result["fields"]), ("drift", ["body"]))

    def test_a_simple_file_against_an_enriched_one_is_drift_in_the_body(self):
        result = self.verdict(make_file(), make_enriched())
        self.assertEqual((result["verdict"], result["fields"]), ("drift", ["body"]))

    def test_an_enriched_tail_that_is_not_the_template_shape_is_not_ignored(self):
        a = make_enriched()
        b = make_enriched().replace("*歸檔日期：2026-02-01*", "*歸檔日期：2026-02-01*\n\n## 額外區段\n\nsomething")
        self.assertEqual(self.verdict(a, b)["verdict"], "drift")

    def test_fields_outside_the_table_are_never_ignored(self):
        cases = [
            (make_file(in_reply_to='"<x@example.invalid>"'), make_file(), ["in_reply_to"]),
            (make_file(extra=("account: work",)), make_file(), ["account"]),
            (make_file(sender="a@example.invalid"), make_file(sender="z@example.invalid"), ["sender"]),
            (make_file(thread_key="Topic"), make_file(thread_key="Other"), ["thread_key"]),
            (make_file(extra=("body_type: text",)), make_file(extra=("body_type: html",)), ["body_type"]),
            (make_file(date="2026-01-28T08:35:34Z"), make_file(date="2026-01-28T08:35:35Z"), ["date"]),
            (make_file(extra=("message_id_missing: true",)), make_file(), ["message_id_missing"]),
        ]
        for a, b, fields in cases:
            with self.subTest(fields=fields):
                result = self.verdict(a, b)
                self.assertEqual((result["verdict"], result["fields"]), ("drift", fields))

    def test_a_single_character_in_the_body_is_drift_and_only_counts_are_reported(self):
        result = self.verdict(make_file(body="Hello world"), make_file(body="Hello worle"))
        self.assertEqual((result["verdict"], result["fields"]), ("drift", ["body"]))
        self.assertEqual(result["body_diff"], {"lines": [7, 7], "chars": [106, 106], "first_difference_line": 7})

    def test_cc_lines_present_on_both_sides_must_agree(self):
        result = self.verdict(make_file(cc="C <c@example.invalid>"), make_file(cc="D <d@example.invalid>"))
        self.assertEqual((result["verdict"], result["fields"]), ("drift", ["body"]))

    def test_other_header_lines_are_not_covered_by_the_cc_exception(self):
        result = self.verdict(make_file(date_line="2026-01-28 08:35"), make_file(date_line="2026-01-28 16:35"))
        self.assertEqual((result["verdict"], result["fields"]), ("drift", ["body"]))

    def test_quote_style_of_a_scalar_is_not_a_difference_but_its_content_is(self):
        quoted = make_file().replace("sender: a@example.invalid", 'sender: "a@example.invalid"')
        self.assertEqual(self.verdict(quoted, make_file())["verdict"], "identical")

    def test_frontmatter_outside_the_template_shape_is_unverifiable(self):
        good = make_file()
        broken = [
            good.replace("---\n", "", 1),                                # no opening fence
            good.replace('thread_key: "Topic"', "thread_key: [a, b]"),    # flow sequence
            good.replace("sender: a@example.invalid", "sender: a@example.invalid\n  nested: x"),
            good.replace("direction: received", "direction: received\ndirection: sent"),   # duplicate key
            good.replace("direction: received", "bad key: received"),
            good.replace('thread_key: "Topic"', "thread_key: 'Topic'"),    # single-quoted scalar
            good.replace('thread_key: "Topic"', 'thread_key: "Topic" trailing'),
            good.replace("direction: received", "direction: &anchor received"),
            good.replace("\n---\n\nSubject", "\nSubject"),            # no closing fence
        ]
        for text in broken:
            for a, b in ((text, good), (good, text)):
                with self.subTest(text=text[:60]):
                    self.assertEqual(self.verdict(a, b), {"verdict": "unverifiable", "fields": [], "ignored": []})

    def test_unverifiable_wins_over_drift_and_nothing_is_echoed_back(self):
        a = make_file(sender=f"{SENTINEL}@example.invalid", thread_key=f"{SENTINEL} one", body=f"{SENTINEL} body",
                      extra=(f"{SENTINEL.replace('-', '_')}: {SENTINEL}",))
        b = make_file(sender="z@example.invalid", thread_key=f"{SENTINEL} two", body="different")
        for pair in ((a, b), (b, a), (a, a.replace("---\n", "", 1))):
            text = json.dumps(self.verdict(*pair))
            self.assertNotIn(SENTINEL, text)
        self.assertNotIn(SENTINEL, json.dumps(self.verdict(a, b, self.zone("UTC"))))

    def test_field_names_that_are_not_plain_identifiers_make_the_pair_unverifiable(self):
        odd = make_file().replace("direction: received", f"{'k' * 65}: received")
        self.assertEqual(self.verdict(odd, make_file())["verdict"], "unverifiable")

    def test_reply_prefix_list_is_the_one_in_archive_mail_md(self):
        text = ARCHIVE.read_text()
        line = next(l for l in text.splitlines() if l.lstrip().startswith("1. 去掉前綴"))
        documented = {item.lower().rstrip(":") for item in re.findall(r"`([^`]+:)`", line)}
        self.assertEqual(documented, set(self.recipe["REPLY_PREFIXES"]))
        strip = self.recipe["strip_reply_prefixes"]
        self.assertEqual(strip("RE: re:  FWD: 回覆: 回复: 轉寄: 转发: fw: Topic "), "Topic")
        self.assertEqual(strip("Re: Re:"), "no-subject")
        self.assertEqual(strip("Reply about it"), "Reply about it")

    def test_files_are_read_by_the_program_and_must_be_regular_files_inside_the_target(self):
        files = self.recipe["classify_pair_files"]
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as elsewhere:
            target = Path(root)
            (target / "a.md").write_text(make_file(message_id="synthetic:one"))
            (target / "b.md").write_text(make_file())
            (Path(elsewhere) / "outside.md").write_text(make_file())
            (target / "link.md").symlink_to(target / "b.md")
            (target / "binary.md").write_bytes(b"\xff\xfe\x00")
            self.assertEqual(files(str(target / "a.md"), str(target / "b.md"), str(target))["verdict"], "identical")
            for other in (target / "link.md", Path(elsewhere) / "outside.md", target / "binary.md", target / "missing.md"):
                with self.subTest(other=other.name):
                    self.assertEqual(files(str(target / "a.md"), str(other), str(target))["verdict"], "unverifiable")


class PlanRecipeCommandLineTests(unittest.TestCase):
    def run_cli(self, command, payload):
        with tempfile.TemporaryDirectory() as work, tempfile.TemporaryDirectory() as data:
            script = Path(work) / "repair_recipe.py"
            script.write_text(recipe_code(SOP, "archive-mail-repair-plan-recipe") + "\n")
            source, target = Path(data) / "in.json", Path(data) / "out.json"
            source.write_text(json.dumps(payload))
            done = subprocess.run([sys.executable, "-I", str(script), command, str(source), str(target)],
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            return json.loads(target.read_text())

    def test_the_command_line_reads_a_json_file_and_writes_a_json_file(self):
        result = self.run_cli("residue-report", {"index_after": {}, "files_after": [], "touched": []})
        self.assertEqual(result["status"], "completed")
        result = self.run_cli("check-index-references", {
            "index": {}, "scanned": [{"file": "a.md", "message_id": "synthetic:one"}],
            "groups": [{"key": TRUE_KEY, "files": ["a.md"]}]})
        self.assertEqual(result["rejections"], [])

    def test_an_unknown_command_is_refused(self):
        with tempfile.TemporaryDirectory() as work:
            script = Path(work) / "repair_recipe.py"
            script.write_text(recipe_code(SOP, "archive-mail-repair-plan-recipe") + "\n")
            done = subprocess.run([sys.executable, "-I", str(script), "nope", "a", "b"], capture_output=True, text=True)
            self.assertNotEqual(done.returncode, 0)


if __name__ == "__main__":
    unittest.main()
