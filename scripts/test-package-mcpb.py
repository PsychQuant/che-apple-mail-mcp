#!/usr/bin/env python3
"""Exercise the real packager in an isolated repository-shaped fixture."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


class PackageSidecarTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mcpb-sidecar-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "mcpb/server").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/package-mcpb.sh", self.root / "scripts/package-mcpb.sh")
        (self.root / "mcpb/manifest.json").write_text(json.dumps({"version": "3.1.0"}))
        (self.root / "mcpb/icon.png").write_bytes(b"fixture-icon")
        (self.root / "mcpb/PRIVACY.md").write_text("fixture privacy")
        (self.root / "mcpb/server/local-only.txt").write_text("must not be bundled")
        self.binary = self.root / "input"
        self.output = self.root / "result.mcpb"
        self.env = os.environ.copy()
        self.env["MCPB_ALLOW_UNSIGNED"] = "1"

    def executable(self, body):
        self.binary.write_text('#!/bin/sh\n[ "$1" = "--version" ] || exit 99\n' + body)
        self.binary.chmod(0o755)

    def package(self):
        return subprocess.run(["/bin/bash", "scripts/package-mcpb.sh", str(self.binary), str(self.output)],
                              cwd=self.root, env=self.env, capture_output=True, text=True, timeout=12)

    def test_archive_contains_executable_derived_sidecar(self):
        self.executable("printf '3.1.0\\n'\n")
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read("server/.CheAppleMailMCP.version"), b"3.1.0\n")
            self.assertEqual(archive.read("server/CheAppleMailMCP"), self.binary.read_bytes())
            self.assertNotIn("server/local-only.txt", archive.namelist())
        self.assertFalse((self.root / "mcpb/server/.CheAppleMailMCP.version").exists())

    def test_mismatched_binary_is_not_relabelled_from_manifest(self):
        self.executable("printf '2.99.0\\n'\n")
        self.output.write_bytes(b"previous-package")
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version", result.stderr.lower())
        self.assertEqual(self.output.read_bytes(), b"previous-package")

    def test_invalid_or_failed_version_query_preserves_output(self):
        for body in ["printf '3.1.0\\nextra\\n'\n", "printf '3.1.0\\n'; exit 1\n"]:
            with self.subTest(body=body):
                self.executable(body)
                self.output.write_bytes(b"previous-package")
                self.assertNotEqual(self.package().returncode, 0)
                self.assertEqual(self.output.read_bytes(), b"previous-package")

    def test_version_query_is_bounded(self):
        self.executable("exec /bin/sleep 30\n")
        self.output.write_bytes(b"previous-package")
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", result.stderr)
        self.assertEqual(self.output.read_bytes(), b"previous-package")

    def test_distribution_gate_still_rejects_unsigned_fixture(self):
        self.executable("printf '3.1.0\\n'\n")
        self.env.pop("MCPB_ALLOW_UNSIGNED", None)
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to package", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
