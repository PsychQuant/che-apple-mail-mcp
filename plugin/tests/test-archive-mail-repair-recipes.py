#!/usr/bin/env python3
"""Execute the repair SOP's Message-ID recipe against the fixture shared with Swift (#529).

Stage 4 of the repair command used to tell the agent to derive the stored spelling of a Message-ID by hand from the raw
`get_email_headers` text. The recipe between `<!-- archive-mail-repair-message-id-recipe:start/end -->` replaces that
derivation, and `plugin/tests/fixtures/repair-message-id-spelling.json` is the single list of cases for both sides:

* `swift_stored` is what the real `RFC822Parser.parseHeaders` puts in `message-id`, which is what a batch export
  stores and what `skipMessageIds` later compares exactly. Tests/CheAppleMailMCPTests/RepairMessageIDSpellingFixtureTests.swift
  checks that column against the parser and runs the export round trip.
* `recipe` is what this recipe must answer. For an `ok` case its `stored` must equal `swift_stored`; for an `unusable`
  case there is no equality to keep, the recipe refuses and the file stays as it is.

This file runs the recipe text taken from the SOP, never a second copy of it. Fixtures use example.invalid only.
It carries its own small loader: the Swift runner executes it with runpy, where the script's directory is not on sys.path.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


TESTS = Path(__file__).resolve().parent
SOP = TESTS.parent / "commands/archive-mail-repair-synthetic-ids.md"
FIXTURE = TESTS / "fixtures/repair-message-id-spelling.json"
MESSAGE_ID_RECIPE = "archive-mail-repair-message-id-recipe"
PLAN_RECIPE = "archive-mail-repair-plan-recipe"
GROUP_STATUSES = {"unique", "candidate-message-id-missing", "message-id-collision", "message-id-format-collision"}


def recipe_code(document, marker):
    text = document.read_text()
    for edge in ("start", "end"):
        if f"<!-- {marker}:{edge} -->" not in text:
            raise AssertionError(f"{document.name} has no <!-- {marker}:{edge} --> marker")
    block = text.split(f"<!-- {marker}:start -->", 1)[1].split(f"<!-- {marker}:end -->", 1)[0]
    return re.fullmatch(r"\s*```python\n(.*?)\n```\s*", block, re.S).group(1)


def load(*markers):
    namespace = {"__name__": "archive_recipe"}
    for marker in markers:
        exec(compile(recipe_code(SOP, marker), f"{SOP}:{marker}", "exec"), namespace)
    return namespace


def fixture():
    return json.loads(FIXTURE.read_text())


def block(message_id_line):
    return f"Subject: s\r\n{message_id_line}\r\n\r\n"


def candidate(ref, message_id_line):
    return {"ref": ref, "headers": block(message_id_line)}


class LoaderTests(unittest.TestCase):
    def test_a_missing_block_is_named_in_the_failure_instead_of_an_index_error(self):
        with self.assertRaises(AssertionError) as raised:
            recipe_code(SOP, "archive-mail-repair-no-such-recipe")
        self.assertIn("archive-mail-repair-no-such-recipe", str(raised.exception))


class FixtureShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = fixture()

    def test_every_category_has_a_case_and_every_case_names_a_listed_category(self):
        used = [case["category"] for case in self.data["cases"]]
        self.assertEqual(set(used), set(self.data["categories"]), "a category lost all its cases, or a case invented one")
        self.assertEqual(len(self.data["categories"]), len(set(self.data["categories"])))

    def test_case_ids_are_unique_and_each_case_has_the_documented_fields(self):
        ids = [case["id"] for case in self.data["cases"]]
        self.assertEqual(len(ids), len(set(ids)))
        for case in self.data["cases"]:
            with self.subTest(case=case["id"]):
                self.assertEqual(set(case), {"id", "category", "raw", "swift_stored", "recipe"})
                self.assertIsInstance(case["raw"], str)
                self.assertIsInstance(case["swift_stored"], str)
                self.assertIn(case["recipe"]["status"], {"ok", "unusable"})

    def test_the_fixture_stays_free_of_real_addresses(self):
        text = FIXTURE.read_text()
        for address in re.findall(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+)", text):
            self.assertTrue(address.lower().endswith("example.invalid"), address)


class MessageIdSpellingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.recipe = load(MESSAGE_ID_RECIPE)
        cls.data = fixture()

    def test_every_case_gets_the_answer_the_fixture_records(self):
        for case in self.data["cases"]:
            with self.subTest(case=case["id"]):
                self.assertEqual(self.recipe["parse_message_id"](case["raw"]), case["recipe"])

    def test_an_ok_answer_stores_exactly_what_the_parser_stores(self):
        ok_cases = [case for case in self.data["cases"] if case["recipe"]["status"] == "ok"]
        self.assertGreaterEqual(len(ok_cases), 10, "the fixture lost most of its usable cases")
        for case in ok_cases:
            with self.subTest(case=case["id"]):
                self.assertEqual(self.recipe["parse_message_id"](case["raw"])["stored"], case["swift_stored"])

    def test_the_comparison_value_is_the_stored_value_without_one_pair_of_brackets(self):
        for case in self.data["cases"]:
            if case["recipe"]["status"] != "ok":
                continue
            stored, comparison = case["recipe"]["stored"], case["recipe"]["comparison"]
            with self.subTest(case=case["id"]):
                expected = stored[1:-1] if stored.startswith("<") else stored
                self.assertEqual(comparison, expected)

    def test_the_character_sets_are_the_ones_swift_foundation_uses(self):
        data = self.data
        self.assertEqual(sorted(ord(c) for c in self.recipe["TRIMMED_CHARACTERS"]), sorted(data["trimmed_characters"]))
        newline = {ord(c) for c in self.recipe["AMBIGUOUS_LINE_BOUNDARIES"]} | {0x0A, 0x0D}
        self.assertEqual(sorted(newline), sorted(data["newline_characters"]))

    def test_python_default_strip_would_trim_characters_foundation_keeps(self):
        # Why the character set is written out: str.strip() also removes U+001C-U+001F, which Foundation does not.
        case = next(case for case in self.data["cases"] if case["id"] == "outer-unit-separator")
        self.assertEqual(case["raw"].split(":", 1)[1].strip(), "<a@example.invalid>")
        self.assertNotEqual(case["swift_stored"], "<a@example.invalid>")
        self.assertEqual(self.recipe["parse_message_id"](case["raw"])["status"], "unusable")

    def test_non_text_input_fails_loudly(self):
        for bad in (None, 3, b"Message-ID: <a@example.invalid>"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.recipe["parse_message_id"](bad)


class CandidateGroupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.classify = staticmethod(load(MESSAGE_ID_RECIPE)["classify_candidates"])
        cls.table_codes = cls.reason_codes()

    @staticmethod
    def reason_codes():
        text = SOP.read_text()
        codes = text.split("<!-- archive-mail-repair-codes:start -->", 1)[1].split("<!-- archive-mail-repair-codes:end -->", 1)[0]
        return set(re.findall(r"^\| `([a-z]+(?:-[a-z]+)+)` \|", codes, re.M))

    def test_copies_of_one_message_in_several_mailboxes_are_one_candidate(self):
        result = self.classify([candidate("101", "Message-ID: <same@example.invalid>"),
                                candidate("202", "Message-ID: <same@example.invalid>"),
                                candidate("303", "message-id:\r\n <same@example.invalid>")])
        self.assertEqual(result["status"], "unique")
        self.assertEqual(result["comparison"], "same@example.invalid")
        self.assertEqual(result["stored"], "<same@example.invalid>")
        self.assertEqual(result["refs"], ["101", "202", "303"])

    def test_one_comparison_value_in_two_spellings_is_a_format_collision(self):
        result = self.classify([candidate("1", "Message-ID: <x@example.invalid>"), candidate("2", "Message-ID: x@example.invalid")])
        self.assertEqual(result["status"], "message-id-format-collision")

    def test_two_comparison_values_are_a_collision_and_case_is_a_difference(self):
        different = self.classify([candidate("1", "Message-ID: <a@example.invalid>"), candidate("2", "Message-ID: <b@example.invalid>")])
        cased = self.classify([candidate("1", "Message-ID: <X@example.invalid>"), candidate("2", "Message-ID: <x@example.invalid>")])
        self.assertEqual(different["status"], "message-id-collision")
        self.assertEqual(cased["status"], "message-id-collision")

    def test_one_unusable_candidate_makes_the_whole_group_missing(self):
        for broken in ("Message-ID: <a@example.invalid", "X-Other: 1", "Message-ID: <a@example.invalid>\r\nMessage-ID: <a@example.invalid>"):
            with self.subTest(broken=broken):
                result = self.classify([candidate("1", "Message-ID: <a@example.invalid>"), candidate("2", broken)])
                self.assertEqual(result["status"], "candidate-message-id-missing")

    def test_when_several_conditions_hold_missing_beats_collision_beats_format_collision(self):
        collision_and_spelling = self.classify([candidate("1", "Message-ID: <a@example.invalid>"), candidate("2", "Message-ID: a@example.invalid"),
                                                candidate("3", "Message-ID: <b@example.invalid>")])
        self.assertEqual(collision_and_spelling["status"], "message-id-collision")
        everything = self.classify([candidate("1", "Message-ID: <a@example.invalid>"), candidate("2", "Message-ID: <b@example.invalid>"),
                                    candidate("3", "X-Other: 1")])
        self.assertEqual(everything["status"], "candidate-message-id-missing")

    def test_the_group_status_vocabulary_is_unique_plus_codes_from_the_closed_table(self):
        seen = {
            self.classify([candidate("1", "Message-ID: <a@example.invalid>")])["status"],
            self.classify([candidate("1", "Message-ID: <a@example.invalid>"), candidate("2", "Message-ID: a@example.invalid")])["status"],
            self.classify([candidate("1", "Message-ID: <a@example.invalid>"), candidate("2", "Message-ID: <b@example.invalid>")])["status"],
            self.classify([candidate("1", "X-Other: 1")])["status"],
        }
        self.assertEqual(seen, GROUP_STATUSES)
        self.assertEqual(seen - {"unique"} - self.table_codes, set(), "a group status that is not in the closed reason table")

    def test_each_candidate_keeps_its_ref_and_its_own_answer(self):
        result = self.classify([candidate("1", "Message-ID: <a@example.invalid>"), candidate("2", "X-Other: 1")])
        self.assertEqual([c["ref"] for c in result["candidates"]], ["1", "2"])
        self.assertEqual(result["candidates"][1]["status"], "unusable")
        self.assertEqual(result["candidates"][1]["reason"], "absent")

    def test_malformed_input_is_an_error_not_an_empty_or_unique_answer(self):
        good = candidate("1", "Message-ID: <a@example.invalid>")
        for bad in ([], None, "x", [good, good], [{"ref": "1"}], [{"headers": "x"}], [{"ref": 1, "headers": "x"}], [{"ref": "1", "headers": None}], ["x"]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.classify(bad)


class CommandLineTests(unittest.TestCase):
    def run_cli(self, command, payload, directory):
        script = Path(directory) / "repair_recipe.py"
        script.write_text("\n".join(recipe_code(SOP, marker) for marker in (MESSAGE_ID_RECIPE, PLAN_RECIPE)) + "\n")
        source, target = Path(directory) / "in.json", Path(directory) / "out.json"
        source.write_text(json.dumps(payload))
        done = subprocess.run([sys.executable, "-I", str(script), command, str(source), str(target)], capture_output=True, text=True)
        return done, target

    def test_classify_candidates_reads_a_json_file_and_writes_a_json_file(self):
        with tempfile.TemporaryDirectory() as work:
            done, target = self.run_cli("classify-candidates", {"candidates": [candidate("1", "Message-ID: <a@example.invalid>")]}, work)
            self.assertEqual(done.returncode, 0, done.stderr)
            result = json.loads(target.read_text())
            self.assertEqual((result["status"], result["stored"]), ("unique", "<a@example.invalid>"))

    def test_paths_with_shell_metacharacters_are_just_paths(self):
        with tempfile.TemporaryDirectory() as root:
            for name in ("$(touch PWNED)", "`touch PWNED`", "a'b;touch PWNED", 'q"uote'):
                work = Path(root) / name
                work.mkdir()
                done, target = self.run_cli("classify-candidates", {"candidates": [candidate("1", "Message-ID: <a@example.invalid>")]}, work)
                with self.subTest(name=name):
                    self.assertEqual(done.returncode, 0, done.stderr)
                    self.assertEqual(json.loads(target.read_text())["status"], "unique")
            self.assertEqual([p.name for p in Path(root).iterdir() if p.name == "PWNED"], [])

    def test_the_header_text_travels_as_data_even_when_it_looks_like_code(self):
        # Inert text: it is only ever written into a JSON file and parsed, never executed (the assertion below proves it).
        hostile = "Message-ID: <a@example.invalid>\r\nSubject: $(touch PWNED) `touch PWNED` \"; import os; os.system('touch PWNED')\r\n\r\n"
        with tempfile.TemporaryDirectory() as work:
            done, target = self.run_cli("classify-candidates", {"candidates": [{"ref": "1", "headers": hostile}]}, work)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(json.loads(target.read_text())["status"], "unique")
            self.assertFalse((Path(work) / "PWNED").exists())

    def test_an_input_the_recipe_refuses_makes_the_program_fail_instead_of_writing_an_answer(self):
        with tempfile.TemporaryDirectory() as work:
            done, target = self.run_cli("classify-candidates", {"candidates": []}, work)
            self.assertNotEqual(done.returncode, 0)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
