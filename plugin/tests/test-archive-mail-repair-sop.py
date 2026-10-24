#!/usr/bin/env python3
"""Vocabulary pins for /archive-mail-repair-synthetic-ids (#525).

The repair command reports a closed set of status words and `still-unparseable` reason codes. These tests read the
shipped SOP text, not a second copy of the lists: the table between the `archive-mail-repair-codes` markers is the
only definition, and everything else in the document must agree with it in both directions.
"""
from pathlib import Path
import re
import unittest


DOCUMENT = Path(__file__).resolve().parents[1] / "commands/archive-mail-repair-synthetic-ids.md"
STOP_STATUSES = ("environment-unavailable", "lookup-unavailable", "apply-unavailable", "apply-incomplete")

# Expected vocabulary at this point of the cluster. Each later commit that adds a word edits these two sets.
EXPECTED_STATUS = {
    "completed", "environment-unavailable", "lookup-unavailable", "apply-unavailable", "apply-incomplete",
}
EXPECTED_REASONS = {
    "subject-unavailable", "sender-unavailable", "date-offset-missing", "date-unparseable",
    "search-truncated", "candidate-sender-unparseable", "candidate-date-unparseable", "no-match",
    "candidate-message-id-missing", "message-id-format-collision", "message-id-collision",
    "quarantine-destination-conflict",
    "old-key-entry-conflict", "existing-key-spelling-mismatch", "duplicate-unverifiable",
    "duplicate-content-drift", "dependent-group-rejected",
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


if __name__ == "__main__":
    unittest.main()
