#!/usr/bin/env python3
"""Execute the shipped SOP recipes, rather than a second implementation."""
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
    block = text.split(f"<!-- archive-mail-{name}-recipe:start -->", 1)[1]
    block = block.split(f"<!-- archive-mail-{name}-recipe:end -->", 1)[0]
    code = re.fullmatch(r"\s*```python\n(.*?)\n```\s*", block, re.S).group(1)
    return code


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


if __name__ == "__main__":
    unittest.main()
