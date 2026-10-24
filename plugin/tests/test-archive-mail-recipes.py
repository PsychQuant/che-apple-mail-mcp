#!/usr/bin/env python3
"""Execute the shipped SOP recipes, rather than a second implementation."""
import itertools
import json
from pathlib import Path
import re
import string
import shlex
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import unquote, urlsplit


DOCUMENT = Path(__file__).resolve().parents[1] / "commands/archive-mail.md"


def recipe_code(name):
    text = DOCUMENT.read_text()
    start = f"<!-- archive-mail-{name}-recipe:start -->"
    end = f"<!-- archive-mail-{name}-recipe:end -->"
    for marker in (start, end):
        if marker not in text:
            raise AssertionError(f"{DOCUMENT.name} is missing the marker {marker}")
    block = text.split(start, 1)[1].split(end, 1)[0]
    match = re.fullmatch(r"\s*```python\n(.*?)\n```\s*", block, re.S)
    if match is None:
        raise AssertionError(f"the {name} recipe is not exactly one ```python block between its markers")
    return match.group(1)


def recipe(name):
    code = recipe_code(name)
    namespace = {"__name__": "archive_recipe"}
    exec(compile(code, str(DOCUMENT) + ":" + name, "exec"), namespace)
    return namespace


class ArchiveDateRecipesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dates = recipe("date")

    def test_truncated_rfc822_and_full_rfc822_preserve_calendar_day(self):
        parse = self.dates["to_ymd"]
        for value in ["Tue, 30 Jun 2026", "30 Jun 2026", "tue, 30 JUN 2026",
                      "Tue, 30 Jun 2026 19:43:20 +0800 (CST)",
                      "Tue, 30 Jun 2026 00:30:00 +0800"]:
            with self.subTest(value=value):
                self.assertEqual(parse(value), "2026-06-30")

    def test_iso_dates_and_legacy_naive_datetime_keep_their_calendar_day(self):
        parse = self.dates["to_ymd"]
        for value in ["2026-06-30", "2026-06-30 14:30", "2026-06-30T00:30:00+08:00",
                      "2026-06-30T23:59:00-08:00", "2026-06-30T12:00:00Z"]:
            with self.subTest(value=value):
                self.assertEqual(parse(value), "2026-06-30")

    def test_iso_offsets_reject_overflow_without_normalizing_or_mutating(self):
        bad = ["2026-06-30T12:00:00" + zone for zone in
               ["+08:60", "-08:60", "+0860", "-0060", "+08:59:60",
                "+085960", "+08:60:00.25", "+24:00", "Z:60", "Z:00", "Z.5"]]
        entries = {str(i): {"date": value, "file": "kept.md"} for i, value in enumerate(bad)}
        before = json.loads(json.dumps(entries))
        for value in bad:
            with self.subTest(value=value):
                self.assertIsNone(self.dates["to_ymd"](value))
                self.assertIsNone(self.dates["normalize_archive_timestamp"](value))
        audit = self.dates["reconcile_dates"](entries)
        self.assertEqual(audit["date_excluded_count"], len(bad))
        self.assertEqual(audit["last_updated"], "")
        self.assertEqual(entries, before)
        for zone in ["+08", "+0800", "+08:00", "-23:59"]:
            with self.subTest(zone=zone):
                value = "2026-06-30T12:00:00" + zone
                self.assertEqual(self.dates["to_ymd"](value), "2026-06-30")
                self.assertIsNotNone(self.dates["normalize_archive_timestamp"](value))
        # a sub-minute offset is a valid day but not a valid RFC 3339 offset: the writer refuses it
        self.assertEqual(self.dates["to_ymd"]("2026-06-30T12:00:00+08:59:59.5"), "2026-06-30")
        self.assertIsNone(self.dates["normalize_archive_timestamp"]("2026-06-30T12:00:00+08:59:59.5"))

    def test_calendar_validation_and_nonstring_values_do_not_crash_or_guess(self):
        parse = self.dates["to_ymd"]
        for value in [None, "", "  ", 20260630, False, [], {}, "2026-02-31",
                      "Tue, 31 Jun 2026", "Thu, 29 Feb 2025", "Tue, 30 Jun 0000",
                      "Tue, 30 Foo 2026", "Tue, 30 Jun 2026 trailing", "30/06/2026",
                      "2026-06-30junk", "2026-06-30T99:99:99Z"]:
            with self.subTest(value=value):
                self.assertIsNone(parse(value))
        self.assertEqual(parse("Thu, 29 Feb 2024"), "2024-02-29")

    def test_explicit_rfc_years_are_not_silently_pivoted(self):
        parse = self.dates["to_ymd"]
        for template in ["Tue, 30 Jun {year} 19:43:20 +0800",
                         "Tuesday, 30-Jun-{year} 19:43:20 GMT",
                         "Tue Jun 30 19:43:20 {year}",
                         "Tue, 30 June {year} 19:43:20 +0800"]:
            with self.subTest(template=template):
                self.assertIsNone(parse(template.format(year="0000")))
                self.assertEqual(parse(template.format(year="0068")), "0068-06-30")
                self.assertEqual(parse(template.format(year="1968")), "1968-06-30")
        self.assertEqual(parse("Tue, 30 Jun 68 19:43:20 +0800"), "2068-06-30")
        audit = self.dates["reconcile_dates"]({
            "bad": {"date": "Tue, 30 Jun 0000 19:43:20 +0800"},
            "ancient": {"date": "Tue, 30 Jun 0068 19:43:20 +0800"},
            "normal": {"date": "2026-06-30"},
        })
        self.assertEqual(audit["last_updated"], "2026-06-30")
        self.assertEqual(audit["date_excluded_count"], 1)

    def test_full_parser_consumes_tokens_and_validates_years_zones_and_comments(self):
        parse = self.dates["to_ymd"]
        for value in ["Tue, 30 Jun 0000, 19:43:20 +0800",
                      "Tue, 00030 Jun 0000 19:43:20 +0800",
                      "Tue, 30 Jun 00000000 19:43:20 +0800",
                      "Tue, 30 Jun 0 19:43:20 +0800"]:
            with self.subTest(value=value):
                self.assertIsNone(parse(value))
        self.assertEqual(parse("Tue, 30 Jun 0068, 19:43:20 +0800"), "0068-06-30")
        self.assertEqual(parse("Tue, 30 Jun 099 19:43:20 +0800"), "0099-06-30")
        self.assertEqual(parse("Tue, 30 Jun 2026 19:43:20 +0800 (CST (local))"), "2026-06-30")
        # Trailing text, an unknown zone or an unterminated comment never change WHICH DAY it is, so the
        # calendar-day recovery keeps them; the timestamp writer must still refuse to turn them into an instant.
        normalize = self.dates["normalize_archive_timestamp"]
        for value in ["Tue, 30 Jun 2026 19:43:20 +0800 garbage",
                      "Tue, 30 Jun 2026 19:43:20 UnknownZone",
                      "Tue, 30 Jun 2026 19:43:20 +2460"]:   # overflowing zone: the writer refuses, the day is still the day
            with self.subTest(value=value):
                self.assertEqual(parse(value), "2026-06-30")
                self.assertIsNone(normalize(value))
        # A truncated comment is exactly what a cut-off header looks like; it cannot change the day either.
        self.assertEqual(parse("Tue, 30 Jun 2026 19:43:20 +0800 (unterminated"), "2026-06-30")
        self.assertIsNone(normalize("Tue, 30 Jun 2026 19:43:20 +0800 (unterminated"))

    def test_timestamp_writer_shares_parser_without_inventing_time_or_zone(self):
        normalize = self.dates["normalize_archive_timestamp"]
        self.assertEqual(normalize("Tue, 30 Jun 0068, 19:43:20 +0800"), "0068-06-30T19:43:20+08:00")
        self.assertEqual(normalize("Tue, 30 Jun 2026 00:30:00 +0800 (CST)"), "2026-06-30T00:30:00+08:00")
        self.assertEqual(normalize("Tue, 30 Jun 2026 19:43:20 GMT"), "2026-06-30T19:43:20+00:00")
        for value in ["Tue, 30 Jun 0000, 19:43:20 +0800", "Tue, 30 Jun 2026",
                      "2026-06-30", "2026-06-30 14:30", "Tue, 30 Jun 2026 19:43:20 -0000",
                      "Tue, 30 Jun 2026 19:43:20 +0800 garbage"]:
            with self.subTest(value=value):
                self.assertIsNone(normalize(value))
        document = DOCUMENT.read_text()
        self.assertNotIn("parsedate_to_datetime(raw).isoformat()", document)
        self.assertGreaterEqual(document.count("normalize_archive_timestamp(raw)"), 2)

    def test_calendar_day_recovery_keeps_the_header_shapes_listed_here(self):
        # #364 verify: a single strict grammar shared by the day reader and the timestamp writer made
        # these real Date: shapes drop out of last_updated. The day reader must keep recovering them.
        to_ymd, normalize = self.dates["to_ymd"], self.dates["normalize_archive_timestamp"]
        for value in ["Tue, 30 Jun 2026 19:43:20 +0800 CST",
                      "Tue, 30 Jun 2026 19:43:20 KST",
                      "Tue, 30 Jun 2026 19:43:20 CET",
                      "Tue, 30 Jun 2026 19:43:20 EST5EDT",
                      "Tue, 30 Jun 2026 19:43:20 0800",
                      "Tue, 30 Jun 2026 7:43:20 PM +0800",
                      "Tue Jun 30 19:43:20 CST 2026"]:
            with self.subTest(value=value):
                self.assertEqual(to_ymd(value), "2026-06-30")
                self.assertIsNone(normalize(value), "the writer must not turn an unknown zone into an instant")

    def test_day_reader_keeps_the_shapes_the_pre_364_parser_recovered_that_round_3_found_lost(self):
        to_ymd, normalize = self.dates["to_ymd"], self.dates["normalize_archive_timestamp"]
        for value in ["Tue, 30 Jun 2026 19.43.20 +0800", "Tue, Jun 30 2026 19:43:20 +0800",
                      "Jun 30 2026 19:43:20 +0800", "Tue, 30 Jun 2026 19:43:20+0800",
                      "Tue, 30 Jun 2026 19:43:20 +0800 (CST", "Tue, 30 Jun 2026 19:43:20 +0800 CST)",
                      "Di, 30 Jun 2026 19:43:20 +0800", "Tues, 30 Jun 2026 19:43:20 +0800",
                      "Tue Jun 30 19:43:20 +0800 2026", "Tue, 30 Jun 19:43:20 2026",
                      "\ufeffTue, 30 Jun 2026 19:43:20 +0800",
                      "Tue Jun 30 2026 19:43:20 GMT+0800 (China Standard Time)",
                      "2026-06-30 19:43:20 +0800", "2026-06-30T19:43:20.123456789Z",
                      "2026-06-30T14:30:00 UTC", "30-Sept-26 10:00:00"]:
            with self.subTest(value=value):
                self.assertEqual(to_ymd(value)[:2], "20")
                self.assertEqual(to_ymd(value)[5:], "09-30" if "Sept" in value else "06-30")
        # a corrupt clock is not a date, on either reader
        for value in ["Tue, 30 Jun 2026 19:43:99 +0800", "Tue Jun 30 19:43:99 2026",
                      "Tue, 30 Jun 2026 24:00:00 +0800", "Tue, 30 Jun 2026 trailing"]:
            with self.subTest(value=value):
                self.assertIsNone(to_ymd(value))
                self.assertIsNone(normalize(value))
        # the writer stays strict: only a shape it can turn into one unambiguous instant is written
        self.assertEqual(normalize("2026-06-30 19:43:20 +0800"), "2026-06-30T19:43:20+08:00")
        self.assertEqual(normalize("2026-06-30T19:43:20.123456789Z"), "2026-06-30T19:43:20.123456+00:00")
        for value in ["Tue, 30 Jun 2026 19.43.20 +0800", "Tue, 30 Jun 2026 19:43:20+0800",
                      "Tue, 30 Jun 2026 19:43:20 -00:00", "Tue, 30 Jun 2026 19:43:20 GMT-0000",
                      "2026-06-30T19:43:20-00:00", "2026-06-30T19:43:20+08:00:30"]:
            with self.subTest(value=value):
                self.assertIsNone(normalize(value))

    def test_round_4_wrong_year_and_wrong_day_inputs_are_rejected_not_guessed(self):
        to_ymd, normalize = self.dates["to_ymd"], self.dates["normalize_archive_timestamp"]
        self.assertEqual(to_ymd("Tue Jun 30 19:43:20 2026 08:00"), "2026-06-30")
        # two bare numbers after the clock: which one is the year cannot be told, so the entry is excluded
        self.assertEqual(to_ymd("Tue Jun 30 07:43:20 PM CST 2026"), "2026-06-30")   # glibc `date` output
        self.assertEqual(to_ymd("Wed Jul  1 07:43:20 AM KST 2026"), "2026-07-01")
        for value in ["Tue Jun 30 19:43:20 45 KST 2026", "Tue Jun 30 19:43:20 2026 CST 45", "Tue Jun 30 19:43:20 CST",
                      "Tue Jun 30 19:43:20 2026 45", "30 Jun 19:43:20 2026 45", "Tue Jun 30 19:43:20 45 2026",
                      "Tue Jun 30 19:43:20 0800 2026", "30 Jun 19:43:20 9999 2026", "Tue Jun 30 19:43:20 12 2026",
                      "Tue Jun 30 19:43:20 KST 19:43", "Week 26 Jun 2026", "Day 1 Jul 2026",
                      "Tue, 30 Jun 202", "Tue, 30 Jun 20", "Tue, 30-Jun-20"]:
            with self.subTest(value=value):
                self.assertIsNone(to_ymd(value))
        self.assertEqual(to_ymd("Tue Jun 30 19:43:20 2026 trailing"), "2026-06-30")
        for zone in ["+08:00:00.5", "-08:00:00.5", "+00:00:00.000001"]:
            with self.subTest(zone=zone):
                self.assertEqual(to_ymd("2026-06-30T12:00:00" + zone), "2026-06-30")
                self.assertIsNone(normalize("2026-06-30T12:00:00" + zone))

    def test_a_corrupt_clock_followed_by_digits_is_never_read_as_a_year(self):
        to_ymd = self.dates["to_ymd"]
        for value in ["Tue Jun 30 19:43:2099", "Tue Jun 30 19:43:200 2026", "30 Jun 19:43:20999",
                      "Tue Jun 30 19:432026", "Tue Jun 30 19:43:20:99 2026"]:
            with self.subTest(value=value):
                self.assertIsNone(to_ymd(value))
        self.assertEqual(to_ymd("Tue Jun 30 19:43:20 +0800 2026"), "2026-06-30")

    def test_explicit_years_are_never_rewritten_on_the_loose_day_reader(self):
        to_ymd = self.dates["to_ymd"]
        self.assertEqual(to_ymd("Tue, 30 Jun 0068 19:43:20 KST"), "0068-06-30")
        # a number that merely appears in a comment cannot stand in for the real year
        self.assertEqual(to_ymd("Tue, 30 Jun 0068 19:43:20 KST (2068)"), "0068-06-30")
        # legacy two-digit years follow the documented pivot on every path
        for value, day in [("Tue, 30 Jun 26 19:43:20 KST", "2026-06-30"), ("Tue, 30 Jun 68 19:43:20 KST", "2068-06-30"),
                           ("Tue, 30 Jun 69 19:43:20 KST", "1969-06-30"), ("Tue, 30 Jun 99 19:43:20 CET", "1999-06-30"),
                           ("Tue Jun 30 19:43:20 CST 26", "2026-06-30")]:
            with self.subTest(value=value):
                self.assertEqual(to_ymd(value), day)

    def test_timestamp_writer_accepts_every_unambiguous_numeric_zone_and_nothing_else(self):
        normalize = self.dates["normalize_archive_timestamp"]
        for value, expected in [("Tue, 30 Jun 2026 19:43:20 +08:00", "2026-06-30T19:43:20+08:00"),
                                ("Tue, 30 Jun 2026 19:43:20 GMT+0800", "2026-06-30T19:43:20+08:00"),
                                ("Tue, 30 Jun 2026 19:43:20 Z", "2026-06-30T19:43:20+00:00"),
                                ("Tue, 30 Jun 2026 19:43:20 -0500", "2026-06-30T19:43:20-05:00")]:
            with self.subTest(value=value):
                self.assertEqual(normalize(value), expected)
        for value in ["Tue, 30 Jun 2026 19:43:20 KST", "Tue, 30 Jun 2026 19:43:20 CET",
                      "Tue, 30 Jun 2026 19:43:20 EST5EDT", "Tue, 30 Jun 2026 19:43:20 +24:00"]:
            with self.subTest(value=value):
                self.assertIsNone(normalize(value))

    def test_fallback_never_accepts_a_pivoted_year_or_malformed_iso(self):
        to_ymd = self.dates["to_ymd"]
        for value in ["Tue, 30 Jun 0000 19:43:20 KST", "Tue, 30 Jun 0 19:43:20 KST",
                      "2026-06-30T12:00:00+08:60", "2026-06-30T14:30:00+08:00[Asia/Taipei]",
                      "2026-06-30_x", "not a date", ""]:
            with self.subTest(value=value):
                self.assertIsNone(to_ymd(value))

    def test_iso_hour_24_and_lowercase_z_are_interpreter_independent(self):
        to_ymd, normalize = self.dates["to_ymd"], self.dates["normalize_archive_timestamp"]
        # Python 3.14's fromisoformat rolls T24:00 into the next day; the recipe rejects it explicitly.
        for value in ["2026-06-30T24:00:00+08:00", "2026-06-30T2400", "2026-06-30T24", "2026-06-30 24",
                      "2026-06-30T240000", "2026-06-30T24+08:00", "2026-06-30T12:00:00+08:00\x00",
                      "2026-06-30T12:00:00+08:60"]:
            with self.subTest(value=value):
                self.assertIsNone(to_ymd(value))
                self.assertIsNone(normalize(value))
        self.assertEqual(to_ymd("2026-06-30T12:00:00z"), "2026-06-30")
        self.assertEqual(normalize("2026-06-30T12:00:00z"), "2026-06-30T12:00:00+00:00")

    def test_exclusions_include_every_index_entry_without_mutating_or_reading_files(self):
        emails = {
            "old": {"date": "2026-06-29T10:00:00+08:00", "file": "old.md"},
            "moved": {"date": "Tue, 30 Jun 2026", "file": "other-workspace/2026-06-30_note.md"},
            "bad": {"date": "unknown", "file": "2027-01-01_do-not-guess.md"},
            "missing": {"file": "missing-date.md"},
            "malformed": None,
        }
        original = json.loads(json.dumps(emails))
        audit = self.dates["reconcile_dates"](emails)
        self.assertEqual(audit["last_updated"], "2026-06-30")
        self.assertEqual(audit["valid_date_count"], 2)
        self.assertEqual(audit["date_excluded_count"], 3)
        self.assertEqual(audit["valid_date_count"] + audit["date_excluded_count"], len(emails))
        self.assertEqual({x["message_id"] for x in audit["date_excluded"]}, {"bad", "missing", "malformed"})
        bad = next(x for x in audit["date_excluded"] if x["message_id"] == "bad")
        self.assertEqual(bad["date"], "unknown")
        self.assertEqual(bad["file"], "2027-01-01_do-not-guess.md")
        self.assertEqual(emails, original)

    def test_all_six_reported_date_only_entries_advance_the_max(self):
        emails = {str(i): {"date": "Tue, 30 Jun 2026", "file": f"subproject/2026-06-30_{i}.md"}
                  for i in range(6)}
        audit = self.dates["reconcile_dates"](emails)
        self.assertEqual(audit["last_updated"], "2026-06-30")
        self.assertEqual(audit["valid_date_count"], 6)
        self.assertEqual(audit["date_excluded_count"], 0)
        self.assertEqual(audit["date_excluded"], [])

    def test_empty_and_all_invalid_never_invent_a_watermark(self):
        for emails, expected_excluded in [({}, 0), ({"x": {"date": "bad"}}, 1)]:
            audit = self.dates["reconcile_dates"](emails)
            self.assertEqual(audit["last_updated"], "")
            self.assertEqual(audit["valid_date_count"], 0)
            self.assertEqual(audit["date_excluded_count"], expected_excluded)


class ArchiveRecipesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.paths = recipe("path")
        cls.inline = recipe("inline")

    def test_normal_names_and_unicode(self):
        safe = self.paths["safe_leaf"]
        for raw, expected in [
            ("Figures & Tables.docx", "Figures & Tables.docx"),
            ("中文附件📎.pdf", "中文附件📎.pdf"),
            ("e\u0301.txt", "é.txt"),
            ("a..b.png", "a..b.png"),
            ("a/b\\c.txt", "abc.txt"),
        ]:
            self.assertEqual(safe(raw), expected)

    def test_dot_segments_and_fallback_cannot_escape(self):
        safe = self.paths["safe_leaf"]
        for raw in ["", ".", "..", " ../", " . . ", "\t/..\\\n"]:
            for fallback in ["", "..", " ../../", "\x00/..\\", "fallback.png"]:
                value = safe(raw, fallback)
                self.assertTrue(self.paths["valid_leaf"](value), (raw, fallback, value))
                self.assertNotIn(value.strip(), ["", ".", ".."])
        self.assertEqual(safe(" ../", " ../../"), "unnamed")

    def test_controls_and_utf8_limit(self):
        safe = self.paths["safe_leaf"]
        for codepoint in list(range(32)) + list(range(127, 160)):
            self.assertEqual(safe("a" + chr(codepoint) + "b"), "ab")
        for raw in ["字" * 300, "📎" * 300, "a" * 199 + "📎"]:
            value = safe(raw)
            self.assertLessEqual(len(value.encode("utf-8")), 200)
            self.assertTrue(self.paths["valid_leaf"](value))

    def test_markdown_label_and_url_have_distinct_encodings(self):
        name = 'x](mailto:evil@example.test)[y]#?% "圖".txt'
        label = self.paths["markdown_label"](name)
        self.assertEqual(re.sub(r"\\([" + re.escape(string.punctuation) + r"])", r"\1", label), name)
        self.assertIn(r"\]\(", label)
        relative = "attachments/" + name
        url = self.paths["relative_link_url"](relative)
        self.assertEqual(unquote(url), relative)
        parsed = urlsplit(url)
        self.assertEqual((parsed.scheme, parsed.netloc, parsed.query, parsed.fragment), ("", "", "", ""))
        for punctuation in '()[]#?%"':
            self.assertIn("%" + format(ord(punctuation), "02X"), url)

    def test_generated_labels_cannot_create_new_lines(self):
        for codepoint in list(range(32)) + list(range(127, 160)):
            label = self.paths["markdown_label"]("a" + chr(codepoint) + "b")
            self.assertFalse(any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in label))
        self.assertFalse(self.paths["valid_leaf"](" \t "))

    def test_yaml_scalar_preserves_astral_unicode(self):
        value = '中文📎 "quoted"\nnext'
        scalar = self.paths["yaml_scalar"](value)
        self.assertEqual(json.loads(scalar), value)
        self.assertIn("📎", scalar)
        self.assertNotIn(r"\ud83d", scalar)
        scalar.encode("utf-8")

    def test_yaml_scalar_escapes_reader_controls_and_line_separators(self):
        for codepoint in list(range(32)) + list(range(127, 160)) + [0x2028, 0x2029, 0xFFFE, 0xFFFF]:
            char = chr(codepoint)
            value = "a" + char + "📎b"
            scalar = self.paths["yaml_scalar"](value)
            self.assertNotIn(char, scalar)
            self.assertEqual(json.loads(scalar), value)

    def test_inline_cli_uses_data_files_and_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script, source, result = root / "recipe.py", root / "input.html", root / "output.json"
            script.write_text(recipe_code("inline"))
            source.write_text('<img alt="name&#9;.png" src="cid:item">')
            subprocess.run([sys.executable, str(script), str(source), str(result)], check=True, timeout=5)
            self.assertEqual(json.loads(result.read_text()), [{"cid": "item", "alt": "name\t.png"}])

    def test_inline_attribute_order_empty_alt_and_dedup(self):
        html = '<IMG ALT="first &amp; image.png" SRC="CID:one"><img src="cid:one" alt="ignored">'
        html += '<img alt="" src="cid:two"><img src="cid:three"><img src="https://example.test/p.png">'
        self.assertEqual(self.inline["extract_inline"](html), [
            {"cid": "one", "alt": "first & image.png"},
            {"cid": "two", "alt": ""},
            {"cid": "three", "alt": None},
        ])

    def test_json_preserves_lookup_keys_without_field_injection(self):
        alt = "tab\tline\nname.png"
        cid = "cid\twith\ncontrols"
        items = self.inline["extract_inline"](f'<img src="cid:{cid}" alt="{alt}">')
        wire = json.dumps(items, ensure_ascii=True)
        self.assertNotIn("\n", wire)
        self.assertNotIn("\t", wire)
        decoded = json.loads(wire)
        self.assertEqual(decoded[0], {"cid": cid, "alt": alt})
        self.assertEqual(self.paths["safe_leaf"](decoded[0]["alt"]), "tablinename.png")

    def test_names_are_data_when_written_with_file_api(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for raw in ["$(touch PWNED)", "`touch PWNED`", "../outside", "a;touch PWNED", "x](mailto:evil)[y]"]:
                name = self.paths["safe_leaf"](raw)
                destination = root / name
                destination.write_text("fixture")
                self.assertEqual(destination.parent, root)
            self.assertFalse((root / "PWNED").exists())

    def test_quoted_shell_paths_do_not_execute_attachment_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for raw in ["$(touch PWNED)", "`touch PWNED`", "a'b;touch PWNED"]:
                path = root / self.paths["safe_leaf"](raw)
                subprocess.run(["/bin/bash", "-c", "mkdir -p -- " + shlex.quote(str(path))],
                               cwd=root, check=True, timeout=5)
                self.assertTrue(path.is_dir())
            self.assertFalse((root / "PWNED").exists())


class ArchiveArgsRecipeTests(unittest.TestCase):
    """#540: how an invocation's text becomes positional arguments plus the --no-confirm flag."""

    @classmethod
    def setUpClass(cls):
        cls.args = recipe("args")
        cls.parse = staticmethod(cls.args["parse_invocation"])

    # raw invocation text -> (positional, no_confirm). Every row is one rule of the closed list in Step 1.
    ACCEPTED = [
        ("filter then flag", "example.invalid --no-confirm", ["example.invalid"], True),
        ("flag only", "--no-confirm", [], True),
        ("two positionals then flag", "a b --no-confirm", ["a", "b"], True),
        ("flag first", "--no-confirm a b", ["a", "b"], True),
        ("flag between positionals", "a --no-confirm b", ["a", "b"], True),
        ("double-quoted name with a space", '"Name With Space" --no-confirm', ["Name With Space"], True),
        ("single-quoted name with a space", "'Name With Space' --no-confirm", ["Name With Space"], True),
        ("backslash-escaped space", r"Name\ With\ Space --no-confirm", ["Name With Space"], True),
        ("CJK name", "陳老師 --no-confirm", ["陳老師"], True),
        ("duplicate flag is the same flag", "--no-confirm a --no-confirm", ["a"], True),
        ("no flag", "a b", ["a", "b"], False),
        ("single positional", "example.invalid", ["example.invalid"], False),
        ("empty", "", [], False),
        ("only whitespace", " \t\n ", [], False),
        ("terminator makes the flag a positional", "-- --no-confirm", ["--no-confirm"], False),
        ("terminator keeps a dash-led directory", "a -- --odd-dir", ["a", "--odd-dir"], False),
        ("flag before the terminator still counts", "a --no-confirm -- --odd-dir", ["a", "--odd-dir"], True),
        ("flag after the terminator is positional", "a -- b --no-confirm", ["a", "b", "--no-confirm"], False),
        ("a second terminator is positional", "a -- b -- c", ["a", "b", "--", "c"], False),
        ("nothing after the terminator", "a --no-confirm --", ["a"], True),
        ("single dash stays positional", "a -x", ["a", "-x"], False),
        ("a quoted flag is still the flag (quotes do not protect it; use --)", '"--no-confirm" a', ["a"], True),
        ("a quoted flag after the terminator is positional", '-- "--no-confirm"', ["--no-confirm"], False),
        ("third positional is returned, not dropped", "a b c", ["a", "b", "c"], False),
        ("no-break and ideographic spaces do not split", "a b　--no-confirm", ["a b　--no-confirm"], False),
    ]

    # raw invocation text -> (error code, offending token)
    REFUSED = [
        ("unknown flag", "--nope", "unknown-flag", "--nope"),
        ("unknown flag after a name", "example.invalid --nope", "unknown-flag", "--nope"),
        ("misspelled flag", "a --no-confrim", "unknown-flag", "--no-confrim"),
        ("flag with a value", "a --no-confirm=1", "unknown-flag", "--no-confirm=1"),
        ("flag in another case", "a --No-Confirm", "unknown-flag", "--No-Confirm"),
        ("em dash from smart punctuation", "a —no-confirm", "unknown-flag", "—no-confirm"),
        ("en dash from smart punctuation", "a –no-confirm", "unknown-flag", "–no-confirm"),
        ("smart double dash", "a ——no-confirm", "unknown-flag", "——no-confirm"),
        ("an unknown flag wins over a known one", "--no-confirm --nope", "unknown-flag", "--nope"),
        ("a quoted unknown flag is still refused", '"--nope" a', "unknown-flag", "--nope"),
        ("unbalanced double quote", '"abc --no-confirm', "unbalanced-quote", None),
        ("apostrophe", "Owner's --no-confirm", "unbalanced-quote", None),
        ("dangling backslash", "a\\", "unbalanced-quote", None),
    ]

    def test_accepted_invocations(self):
        for label, raw, positional, no_confirm in self.ACCEPTED:
            with self.subTest(label):
                result = self.parse(raw)
                self.assertIsNone(result["error"])
                self.assertEqual(result["positional"], positional)
                self.assertIs(result["no_confirm"], no_confirm)

    def test_refused_invocations_name_the_token_and_carry_nothing_to_act_on(self):
        for label, raw, code, token in self.REFUSED:
            with self.subTest(label):
                result = self.parse(raw)
                self.assertEqual(result["error"], {"code": code, "token": token})
                self.assertEqual(result["positional"], [])
                self.assertIs(result["no_confirm"], False)

    def test_error_codes_are_the_two_the_sop_names(self):
        codes = {code for _, _, code, _ in self.REFUSED}
        self.assertEqual(codes, {"unknown-flag", "unbalanced-quote"})

    def test_only_the_exact_flag_sets_it(self):
        for raw in ["a --no-confirmx", "a --no-confirm=", "a --NO-CONFIRM", "a -no-confirm",
                    "a no-confirm", "a --no_confirm", "a ---no-confirm"]:
            with self.subTest(raw):
                result = self.parse(raw)
                self.assertIs(result["no_confirm"], False)

    def test_third_positional_is_never_reassigned_to_the_output_dir(self):
        result = self.parse("a b c --no-confirm")
        self.assertEqual(result["positional"][:2], ["a", "b"])
        self.assertEqual(result["positional"][2:], ["c"])
        self.assertIs(result["no_confirm"], True)

    def test_input_that_is_not_text_is_not_guessed_at(self):
        for value in [None, 5, ["a"]]:
            with self.subTest(value):
                with self.assertRaises(TypeError):
                    self.parse(value)

    def test_positive_control_naive_splitters_answer_the_table_wrong(self):
        # If the table could not tell a real parser from a naive one, passing it would prove nothing.
        def whitespace_only(raw):
            return {"positional": raw.split(), "no_confirm": False, "error": None}

        def flag_aware_whitespace(raw):
            tokens = raw.split()
            return {"positional": [t for t in tokens if t != "--no-confirm"],
                    "no_confirm": "--no-confirm" in tokens, "error": None}

        rows = [(raw, {"positional": positional, "no_confirm": no_confirm, "error": None})
                for _, raw, positional, no_confirm in self.ACCEPTED]
        rows += [(raw, {"positional": [], "no_confirm": False, "error": {"code": code, "token": token}})
                 for _, raw, code, token in self.REFUSED]
        # Every row that carries the flag is answered wrong by a splitter that does not know the flag...
        flagged = [(raw, want) for raw, want in rows if want["no_confirm"]]
        self.assertGreaterEqual(len(flagged), 8)
        for raw, want in flagged:
            with self.subTest("unaware: " + raw):
                self.assertNotEqual(whitespace_only(raw), want)
        # ...and a splitter that knows the flag but not shell quoting, the terminator or the refusals is
        # still answered wrong by a good part of the table: the rows exercise those rules, not just the flag.
        wrong = [raw for raw, want in rows if flag_aware_whitespace(raw) != want]
        self.assertGreaterEqual(len(wrong), 15, wrong)
        for must_differ in ['"Name With Space" --no-confirm', "-- --no-confirm", "a --no-confrim", '"abc --no-confirm']:
            self.assertIn(must_differ, wrong)

    def test_without_quotes_or_backslashes_a_plain_ascii_whitespace_split_gives_the_same_answer(self):
        # The SOP lets the agent skip running the recipe when the text has no quote or backslash.
        # That shortcut is only sound if it is the same function; this pins it, separators included.
        words = ["a", "b", "--", "--no-confirm", "--nope", "-x", "陳老師", "\u2014no-confirm",
                 "a\u3000b", "a\x0bb", "#c"]
        separators = [" ", "  ", "\t", "\n", " \t ", "\r\n"]
        checked = 0
        for count in range(0, 4):
            for combo in itertools.product(words, repeat=count):
                for separator in separators:
                    for padding in ["", " ", "\n"]:
                        raw = padding + separator.join(combo) + padding
                        tokens = [t for t in re.split(r"[ \t\r\n]+", raw) if t]
                        if self.parse(raw) != self.args["apply_rules"](tokens):
                            self.fail("shortcut and recipe disagree on " + repr(raw))
                        checked += 1
        self.assertGreater(checked, 10000)

    def test_the_shortcut_boundary_is_exactly_the_characters_that_change_tokenising(self):
        # The SOP sends text containing " ' or a backslash to the recipe. Each of those really changes
        # how shlex tokenises; every other ASCII punctuation character is an ordinary word character.
        for char in "\"'\\":
            with self.subTest(char=char):
                try:
                    tokens = shlex.split("a" + char + "b c")
                except ValueError:
                    continue
                self.assertNotEqual(tokens, ["a" + char + "b", "c"])
        for char in string.punctuation.replace('"', "").replace("'", "").replace("\\", ""):
            with self.subTest(char=char):
                self.assertEqual(self.parse("a" + char + "b c")["positional"], ["a" + char + "b", "c"])

    def test_cli_reads_the_text_from_a_file_and_treats_it_as_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script, source, result = root / "args_recipe.py", root / "input.txt", root / "output.json"
            script.write_text(recipe_code("args"))
            source.write_text('"$(touch PWNED)" "`touch PWNED`" --no-confirm\n', encoding="utf-8")
            subprocess.run([sys.executable, "-I", str(script), str(source), str(result)],
                           check=True, timeout=5, cwd=root)
            self.assertEqual(json.loads(result.read_text()), {
                "positional": ["$(touch PWNED)", "`touch PWNED`"], "no_confirm": True, "error": None})
            self.assertFalse((root / "PWNED").exists())
            source.write_text("a --nope\n", encoding="utf-8")
            subprocess.run([sys.executable, "-I", str(script), str(source), str(result)],
                           check=True, timeout=5, cwd=root)
            self.assertEqual(json.loads(result.read_text()), {
                "positional": [], "no_confirm": False, "error": {"code": "unknown-flag", "token": "--nope"}})

    def test_cli_rejects_a_wrong_argument_count(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "args_recipe.py"
            script.write_text(recipe_code("args"))
            done = subprocess.run([sys.executable, "-I", str(script)], capture_output=True, timeout=5)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn(b"usage", done.stderr)


PLUGIN = DOCUMENT.parents[1]


def between(text, start, end):
    """The text from `start` up to the next `end`; fails by naming the missing anchor."""
    for anchor in (start, end):
        if anchor not in text:
            raise AssertionError(f"anchor not found: {anchor!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


class ArchiveArgsStructureTests(unittest.TestCase):
    """#540: the command file may read the typed arguments in exactly one place."""

    @classmethod
    def setUpClass(cls):
        cls.document = DOCUMENT.read_text()

    def test_the_only_argument_placeholder_is_the_ARGS_RAW_line(self):
        # Claude Code replaces every unescaped placeholder with the typed text before the agent reads
        # the file, so each extra one re-creates the failure this fixes: the flag showing up as a positional.
        hits = list(re.finditer(r"(?<!\\)\$ARGUMENTS", self.document))
        self.assertEqual(len(hits), 1, [self.document.count("\n", 0, h.start()) + 1 for h in hits])
        start = self.document.rfind("\n", 0, hits[0].start()) + 1
        self.assertEqual(self.document[start:self.document.find("\n", start)], "ARGS_RAW: $ARGUMENTS")

    def test_no_indexed_argument_placeholder_survives_even_escaped(self):
        self.assertEqual(re.findall(r"\\?\$ARGUMENTS\[", self.document), [])

    def test_argument_hint_lists_the_flag_as_one_json_string_line(self):
        lines = [l for l in self.document.split("---", 2)[1].splitlines() if l.startswith("argument-hint:")]
        self.assertEqual(len(lines), 1)
        hint = json.loads(lines[0].split(":", 1)[1].strip())
        self.assertIn("[--no-confirm]", hint)
        self.assertIn("[email-filter] [output-dir]", hint)

    def test_usage_block_shows_the_flag_the_terminator_and_the_unknown_flag_error(self):
        usage = between(self.document, "## 使用方式", "#### 零參數模式")
        self.assertIn("/archive-mail user@example.com --no-confirm", usage)
        self.assertIn("/archive-mail --no-confirm", usage)
        self.assertRegex(usage, r"/archive-mail \S+ -- --")
        self.assertIn("不認得的旗標", usage)

    def test_step_zero_task_text_names_the_parse_step_not_the_placeholder(self):
        task = between(self.document, 'TaskCreate(subject="resolve_filter_and_paths",', "TaskCreate(subject=\"load_participant_identity\"")
        self.assertIn("Step 1 引數解析", task)
        self.assertIn("ARGS_RAW", task)

    def test_flag_only_invocation_takes_the_zero_arg_path(self):
        zero = between(self.document, "#### Zero-arg 模式", "#### 命令列覆寫")
        self.assertIn('if [ "${#POSITIONAL[@]}" -eq 0 ]; then', zero)
        self.assertIn("只給 `--no-confirm`", zero)
        override = between(self.document, "#### 命令列覆寫", "#### Workspace Layout Detection")
        self.assertIn("`POSITIONAL` 非空", override)
        self.assertIn("`POSITIONAL[0]`", override)
        self.assertIn("`OUTPUT_DIR_ARG`", override)

    def test_config_parsing_and_output_dir_precedence_read_the_parsed_variables(self):
        step1 = between(self.document, "#### Config parsing", "#### Zero-arg 模式")
        self.assertIn("`POSITIONAL`", step1)
        self.assertIn("independent of POSITIONAL state", step1)
        self.assertIn("1. OUTPUT_DIR_ARG (cmdline second positional)", step1)
        detection = between(self.document, "#### Workspace Layout Detection", "**Probe 順序**")
        self.assertIn("`OUTPUT_DIR_ARG`", detection)
        self.assertIn("after OUTPUT_DIR_ARG + ${CONFIG_FILE} resolution", self.document)
        precedence = between(self.document, "**Detection 與 explicit config 的關係**", "#### 模糊 filter")
        self.assertIn("1. `OUTPUT_DIR_ARG`", precedence)

    def test_directories_are_created_with_the_terminator(self):
        # "--" lets a directory whose name starts with "-" be an ordinary, valid output_dir.
        self.assertIn('mkdir -p -- "${INDEX_DIR}"', self.document)
        self.assertIn('mkdir -p -- "${output_dir}"', self.document)
        self.assertEqual(re.findall(r'mkdir -p "\$\{(?:INDEX_DIR|output_dir)\}"', self.document), [])

    def test_a_dash_led_output_dir_survives_slug_and_mkdir(self):
        with tempfile.TemporaryDirectory() as directory:
            slug = subprocess.run(
                ["/bin/bash", "-c", r"""printf '%s' "$1" | tr '/' '-' | sed 's/^[-.]*//;s/[-.]*$//'""", "_", "--odd-dir"],
                capture_output=True, text=True, check=True, timeout=5).stdout
            self.assertEqual(slug, "odd-dir")
            made = subprocess.run(["/bin/bash", "-c", 'mkdir -p -- "$1"', "_", "--odd-dir"],
                                  cwd=directory, capture_output=True, text=True, timeout=5)
            self.assertEqual(made.returncode, 0, made.stderr)
            self.assertTrue((Path(directory) / "--odd-dir").is_dir())


class ArchiveNoConfirmAuthorityTests(unittest.TestCase):
    """#540: every place that skips a confirmation names the parsed flag and where it may come from."""

    @classmethod
    def setUpClass(cls):
        cls.document = DOCUMENT.read_text()
        cls.skip_phase_1 = between(cls.document, "**Skip Phase 1**", "詳見 `skills/confirmation-protocol/SKILL.md` 和")
        cls.skip_phase_2_3 = between(cls.document, "**Skip Phase 2+3**", "詳見 `skills/bulk-operation-preview/SKILL.md`")
        cls.step_7 = between(cls.document, "### Step 7: 輸出報告", "### Step 8: 覆蓋率稽核")

    def test_the_old_description_of_a_user_typed_flag_is_gone_everywhere(self):
        self.assertNotIn("user-typed", self.document)

    def test_phase_1_skip_list_cites_the_parsed_flag_and_its_only_source(self):
        self.assertIn("`NO_CONFIRM`", self.skip_phase_1)
        self.assertIn("ARGS_RAW", self.skip_phase_1)
        self.assertIn("Provenance", self.skip_phase_1)
        self.assertIn("直接做", self.skip_phase_1)
        for named_non_source in ["郵件內文", "搜尋結果", "config"]:
            self.assertIn(named_non_source, self.skip_phase_1)

    def test_the_mail_334_exception_is_triggered_by_the_parsed_flag(self):
        self.assertIn("mail#334", self.skip_phase_1)
        self.assertIn("使用者以 `NO_CONFIRM` 或「直接做」跳過確認", self.skip_phase_1)
        self.assertNotIn("`--no-confirm` 或「直接做」", self.skip_phase_1)

    def test_phase_2_3_skip_list_cites_the_parsed_flag_as_equal_to_just_do_it(self):
        self.assertIn("`NO_CONFIRM`", self.skip_phase_2_3)
        self.assertIn("Provenance", self.skip_phase_2_3)
        self.assertRegex(self.skip_phase_2_3, r"等價於「直接做」")
        self.assertIn("Phase 1–3", self.skip_phase_2_3)

    def test_step_zero_phase_1_task_names_the_parsed_flag(self):
        task = between(self.document, 'TaskCreate(subject="phase1_disambiguation",', 'TaskCreate(subject="load_indices_and_config"')
        self.assertIn("NO_CONFIRM", task)
        self.assertNotIn("明確 email/Message-ID/--no-confirm", task)

    def test_the_report_says_when_a_confirmation_was_skipped_because_of_the_flag(self):
        self.assertIn("確認略過的依據", self.step_7)
        self.assertIn("--no-confirm(使用者叫用)", self.step_7)
        self.assertIn("`NO_CONFIRM` 成立時才顯示", self.step_7)
        self.assertIn("略過: Phase 1、Phase 2+3", self.step_7)

    def test_the_flag_has_exactly_the_authority_of_just_do_it_not_more(self):
        # D2: the flag copies the meaning of 「直接做」. It must not add a skip that 「直接做」 lacks,
        # so neither skip list may mention the flag without also mentioning Provenance.
        for text in (self.skip_phase_1, self.skip_phase_2_3):
            if "NO_CONFIRM" in text:
                self.assertIn("Provenance", text)


if __name__ == "__main__":
    unittest.main()
