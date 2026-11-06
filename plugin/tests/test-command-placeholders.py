#!/usr/bin/env python3
"""#521: no command or skill may carry a positional placeholder that Claude Code would replace.

Claude Code substitutes arguments into the whole command/skill body, code blocks included, before the
model reads it (official skills documentation, "Available string substitutions"):

- `$N` is shorthand for `$ARGUMENTS[N]`, counted from 0: `$0` is the first argument, `$1` the second;
- a `$N` with no matching argument is left as written (Claude Code 2.1.210 and later; earlier versions
  dropped it);
- a single backslash before the `$` escapes it (`\\$0` reaches the model as `$0`, Claude Code 2.1.163
  and later); with two or more backslashes they are all kept and the `$N` is still replaced.

So an awk field (`$0`) or a shell positional parameter (`$1`) written plainly in a command is rewritten
whenever the command is invoked with arguments. Measured on Claude Code 2.1.314 with a probe command in
a scratch directory (#521 diagnosis): `/probe first second` turned `$0` into `first` and `$1` into
`second`, and turned `\\$0` / `\\$1` into `$0` / `$1`.

This test reads files only. It does not prove Claude Code's rule; if the rule changes, this test will
not notice.
"""
from pathlib import Path
import re
import unittest

PLUGIN = Path(__file__).resolve().parents[1]

# `$` followed by a number or by `ARGUMENTS[`: the two forms that select one argument by index.
_PLACEHOLDER = re.compile(r"\$(?:\d+|ARGUMENTS\[)")


def scanned_files() -> list[Path]:
    """Every file whose body Claude Code substitutes arguments into, for this plugin."""
    return sorted(PLUGIN.glob("commands/*.md")) + sorted(PLUGIN.glob("skills/*/SKILL.md"))


def backslashes_before(text: str, index: int) -> int:
    count = 0
    while index - count - 1 >= 0 and text[index - count - 1] == "\\":
        count += 1
    return count


def unescaped_placeholders(text: str) -> list[tuple[int, str]]:
    """(line number, matched text) of each indexed placeholder not escaped by exactly one backslash."""
    hits = []
    for match in _PLACEHOLDER.finditer(text):
        if backslashes_before(text, match.start()) != 1:
            hits.append((text.count("\n", 0, match.start()) + 1, match.group(0)))
    return hits


class ScannerTests(unittest.TestCase):
    """Positive control: without these, a broken scanner would pass every real file silently."""

    def test_plain_placeholders_are_found(self) -> None:
        text = "awk '$0 ~ field'\nif [ \"$1\" = x ]\nprintf $10\nx $ARGUMENTS[0]\n"
        self.assertEqual(unescaped_placeholders(text), [(1, "$0"), (2, "$1"), (3, "$10"), (4, "$ARGUMENTS[")])

    def test_a_single_backslash_escapes(self) -> None:
        self.assertEqual(unescaped_placeholders(r"awk '\$0 ~ field' \$1 \$ARGUMENTS[0]"), [])

    def test_two_or_more_backslashes_do_not_escape(self) -> None:
        self.assertEqual(unescaped_placeholders(r"a \\$1 b \\\$0"), [(1, "$1"), (1, "$0")])

    def test_the_whole_argument_string_and_braced_shell_parameters_are_not_indexed(self) -> None:
        self.assertEqual(unescaped_placeholders('ARGS_RAW: $ARGUMENTS\nprintf "${1}" "$@" $NAME\n'), [])

    def test_a_backslash_at_the_start_of_the_text_is_counted(self) -> None:
        self.assertEqual(unescaped_placeholders(r"\$0"), [])
        self.assertEqual(unescaped_placeholders("$0"), [(1, "$0")])


class PluginFilesTests(unittest.TestCase):

    def test_the_glob_finds_the_commands_and_skills_it_is_meant_to_cover(self) -> None:
        names = {str(path.relative_to(PLUGIN)) for path in scanned_files()}
        self.assertGreater(len(names), 0)
        for required in ("commands/archive-mail.md", "commands/archive-mail-migrate.md",
                         "skills/confirmation-protocol/SKILL.md"):
            self.assertIn(required, names)

    def test_no_command_or_skill_carries_an_unescaped_indexed_placeholder(self) -> None:
        found = {}
        for path in scanned_files():
            hits = unescaped_placeholders(path.read_text(encoding="utf-8"))
            if hits:
                found[str(path.relative_to(PLUGIN))] = hits
        self.assertEqual(found, {}, "escape each with a single backslash (\\$0), or read ARGS_RAW instead")

    def test_removing_the_escape_from_archive_mail_turns_the_scan_red(self) -> None:
        # Mutation on the real file: the awk line that checks the six refinement fields.
        text = (PLUGIN / "commands/archive-mail.md").read_text(encoding="utf-8")
        escaped = "awk -v field=\"^${_f}:\" '\\$0 ~ field {print; exit}'"
        self.assertEqual(text.count(escaped), 1)
        mutated = text.replace(escaped, escaped.replace("\\$0", "$0"))
        self.assertNotEqual(mutated, text)
        self.assertEqual(len(unescaped_placeholders(mutated)), 1)


def escape_comment(text: str) -> str:
    """The `# #521:` comment in archive-mail.md that explains the escaped `\\$0` / `\\$1` below it."""
    start = text.index("# #521:")
    end = text.index("for _f in sender_includes", start)
    # One line of prose: drop each line's indent and leading `#`, so a phrase may wrap across comment lines.
    return " ".join(line.strip().lstrip("#").strip() for line in text[start:end].splitlines())


class EscapeCommentTests(unittest.TestCase):
    """#521 verify: the comment states only what was measured (round 1 findings 3, 10, 28; round 2 7, 15, 20, 27).

    The live probe (2026-11-01, on #521) ran Claude Code 2.1.316 once with and once without arguments. The
    escape syntax first appeared in 2.1.163, but positional substitution changed again at 2.1.210 and 2.1.233,
    and no other version was run, so the comment may not claim a version range or what older versions do.
    """

    CHANGELOG_ENTRY = "issues/521"

    @classmethod
    def setUpClass(cls) -> None:
        cls.comment = escape_comment((PLUGIN / "commands/archive-mail.md").read_text(encoding="utf-8"))
        changelog = (PLUGIN / "CHANGELOG.md").read_text(encoding="utf-8")
        cls.entry = next(line for line in changelog.split("\n") if cls.CHANGELOG_ENTRY in line)

    def test_the_comment_names_the_measured_version_and_both_calls(self) -> None:
        self.assertIn("2.1.316", self.comment)
        self.assertIn("with and without arguments", self.comment)
        self.assertIn("not tested", self.comment)

    def test_neither_the_comment_nor_the_changelog_claims_a_range_or_older_behaviour(self) -> None:
        for name, text in (("comment", self.comment), ("CHANGELOG", self.entry)):
            for claim in ("and later", "older versions keep", "older Claude Code", "or later"):
                with self.subTest(place=name, claim=claim):
                    self.assertNotIn(claim, text)
        self.assertIn("2.1.316", self.entry)

    def test_the_comment_still_tells_a_copier_to_remove_the_backslash(self) -> None:
        self.assertIn("Remove the backslash", self.comment)


def section(text: str, start: str, end: str) -> str:
    for anchor in (start, end):
        if anchor not in text:
            raise AssertionError(f"anchor not found: {anchor!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


class MigrateArgumentsTests(unittest.TestCase):
    """#521: /archive-mail-migrate reads its one flag from ARGS_RAW, the way #540 does for /archive-mail.

    The old Step 1 compared the shell's "$1" to --dry-run. Under the substitution rule `$1` is the
    second argument, and pasted into a new shell it is empty, so a requested preview could be taken
    as a real move. The user decided (2026-10-31) that --dry-run is the first and only argument.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.document = (PLUGIN / "commands/archive-mail-migrate.md").read_text(encoding="utf-8")
        cls.step_1 = section(cls.document, "### Step 1: 解析參數", "### Step 2:")

    def test_the_only_argument_placeholder_is_the_ARGS_RAW_line(self) -> None:
        hits = [m for m in re.finditer(r"\$ARGUMENTS", self.document)
                if backslashes_before(self.document, m.start()) != 1]
        self.assertEqual(len(hits), 1, [self.document.count("\n", 0, m.start()) + 1 for m in hits])
        start = self.document.rfind("\n", 0, hits[0].start()) + 1
        self.assertEqual(self.document[start:self.document.find("\n", start)], "ARGS_RAW: $ARGUMENTS")
        self.assertIn("ARGS_RAW: $ARGUMENTS", self.step_1)

    def test_no_positional_parameter_is_read_even_escaped(self) -> None:
        self.assertIsNone(re.search(r"\$\d", self.document))

    def test_step_1_names_each_outcome_and_stops_on_anything_else(self) -> None:
        for required in ("`--dry-run`", "`DRY_RUN = true`", "`DRY_RUN = false`", "—dry-run",
                         "--dry-run extra", "Error: 不認得的引數", "不得依性質相似類推"):
            self.assertIn(required, self.step_1)
        self.assertIn("不搬任何檔", self.step_1)

    def test_args_raw_never_becomes_code(self) -> None:
        # #521 verify (finding 39): the #540 data-handling rule, in the same words as /archive-mail Step 1.
        self.assertIn("不得把 `ARGS_RAW` 放進 `python3 -c` 文字或 shell 原始碼", self.step_1)

    def test_the_stop_message_names_one_token_not_the_whole_text(self) -> None:
        # #521 verify (finding 39): like /archive-mail's unknown-flag error (#540), echo one token, not ARGS_RAW.
        message = next(line for line in self.step_1.split("\n") if "Error: 不認得的引數" in line)
        self.assertNotIn("<ARGS_RAW>", message)
        self.assertIn("<token>", message)
        self.assertIn("第一個不等於 `--dry-run` 的 token", self.step_1)

    def test_a_repeated_flag_has_its_own_message(self) -> None:
        # #521 verify round 2 (finding 16): `--dry-run --dry-run` is not an unrecognized argument.
        message = next(line for line in self.step_1.split("\n") if "Error: --dry-run 重複" in line)
        self.assertNotIn("不認得", message)
        self.assertNotIn("第二個 token", self.step_1)   # the old rule that echoed --dry-run as unrecognized

    def test_usage_says_which_invocations_stop(self) -> None:
        usage = section(self.document, "## 使用方式", "## 執行步驟")
        self.assertIn("/archive-mail-migrate --dry-run", usage)
        self.assertIn("停止", usage)


class MigrateNoDiskNameInPythonSourceTests(unittest.TestCase):
    """#602: a name found on disk must reach python3 through argv, never inside the program text."""

    DISK_DERIVED = ("INDEX_DIR", "SLUG", "NAMESPACE_DIR", "archive_dir")

    @staticmethod
    def python_sources(text: str) -> list[str]:
        """The quoted program text of every `python3 -c '...'` / `python3 -c "..."` in the text."""
        return [m.group(2) for m in re.finditer(r"python3 -c (['\"])(.*?)\1", text, re.S)]

    def hits(self, text: str) -> list[str]:
        return [name for source in self.python_sources(text) for name in self.DISK_DERIVED if name in source]

    def test_migrate_keeps_disk_derived_names_out_of_python_source(self) -> None:
        text = (PLUGIN / "commands/archive-mail-migrate.md").read_text(encoding="utf-8")
        self.assertTrue(self.python_sources(text), "the guard found no python3 -c; did the command change?")
        self.assertEqual(self.hits(text), [])

    def test_the_index_check_passes_the_path_through_argv(self) -> None:
        text = (PLUGIN / "commands/archive-mail-migrate.md").read_text(encoding="utf-8")
        self.assertIn("json.load(open(sys.argv[1]))' \"${INDEX_DIR}/email_index.json\"", text)

    def test_a_planted_interpolation_turns_the_guard_red(self) -> None:
        planted = "python3 -c \"import json; json.load(open('${INDEX_DIR}/email_index.json'))\""
        self.assertEqual(self.hits(planted), ["INDEX_DIR"])


if __name__ == "__main__":
    unittest.main()
