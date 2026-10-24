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
