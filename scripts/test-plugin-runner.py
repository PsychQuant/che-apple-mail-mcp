#!/usr/bin/env python3
"""Check real Makefile/runner dispatch without recursively running Swift tests."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PluginRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="plugin-runner-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for folder in ["scripts", "plugin/tests", "shim"]:
            (self.root / folder).mkdir(parents=True)
        shutil.copy2(ROOT / "Makefile", self.root / "Makefile")
        shutil.copy2(ROOT / "scripts/test-plugin.sh", self.root / "scripts/test-plugin.sh")
        self.env = {k: v for k, v in os.environ.items() if k not in ["MAKEFLAGS", "MFLAGS", "MAKELEVEL"]}
        self.env.update(PATH=str(self.root / "shim") + ":/usr/bin:/bin", RUNNER_FIXTURE_ROOT=str(self.root))
        self.executable("shim/swift", '[ "$1" = test ] || exit 99\nprintf "swift\\n" >> "$RUNNER_FIXTURE_ROOT/events"\n')
        self.executable("shim/jq", "exit 0\n")
        self.hook = "plugin/tests/test-session-start-hook.sh"
        self.executable(self.hook, 'printf "hook\\n" >> "$RUNNER_FIXTURE_ROOT/events"\n')

    def executable(self, relative, body):
        path = self.root / relative
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_make(self, target):
        return subprocess.run(["/usr/bin/make", target], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=15)

    def events(self):
        path = self.root / "events"
        return path.read_text().splitlines() if path.exists() else []

    def test_full_entry_runs_swift_then_plugin(self):
        result = self.run_make("test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.events(), ["swift", "hook"])

    def test_plugin_failure_reaches_full_entry(self):
        self.executable(self.hook, 'printf "hook\\n" >> "$RUNNER_FIXTURE_ROOT/events"\nexit 7\n')
        self.assertNotEqual(self.run_make("test").returncode, 0)
        self.assertEqual(self.events(), ["swift", "hook"])

    def test_swift_failure_stops_before_plugin(self):
        self.executable("shim/swift", 'printf "swift\\n" >> "$RUNNER_FIXTURE_ROOT/events"\nexit 4\n')
        self.assertNotEqual(self.run_make("test").returncode, 0)
        self.assertEqual(self.events(), ["swift"])

    def test_python_suite_is_discovered_and_failure_propagates(self):
        (self.root / "plugin/tests/test-extra.py").write_text(
            'import os\nfrom pathlib import Path\nPath(os.environ["RUNNER_FIXTURE_ROOT"], "python-called").touch()\nraise SystemExit(9)\n')
        self.assertNotEqual(self.run_make("test-plugin").returncode, 0)
        self.assertTrue((self.root / "python-called").exists())
        self.assertEqual(self.events(), ["hook"])

    def test_missing_hook_suite_is_not_zero_test_success(self):
        (self.root / self.hook).unlink()
        result = self.run_make("test-plugin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required plugin suite missing", result.stderr)

    def test_missing_jq_has_an_actionable_failure(self):
        (self.root / "shim/jq").unlink()
        (self.root / "shim/dirname").symlink_to("/usr/bin/dirname")
        self.env["PATH"] = str(self.root / "shim")
        result = self.run_make("test-plugin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require jq", result.stderr)

    def test_missing_python_fails_before_running_suites(self):
        (self.root / "plugin/tests/test-extra.py").write_text("raise SystemExit(0)\n")
        (self.root / "shim/dirname").symlink_to("/usr/bin/dirname")
        self.env["PATH"] = str(self.root / "shim")
        result = self.run_make("test-plugin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require python3", result.stderr)
        self.assertEqual(self.events(), [])


if __name__ == "__main__":
    unittest.main()
