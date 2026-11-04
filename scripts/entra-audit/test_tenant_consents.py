#!/usr/bin/env python3
"""Tests for tenant_consents_report.py: the report renders the collected shape, and a broken file fails.

    python3 -m unittest scripts/entra-audit/test_tenant_consents.py
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPORT = HERE / "tenant_consents_report.py"


def run(data: object) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "tenant-consents.json"
        path.write_text(json.dumps(data))
        return subprocess.run([sys.executable, str(REPORT), str(path)], capture_output=True, text=True)


class Report(unittest.TestCase):
    def test_renders_both_sections_with_names_and_scopes(self) -> None:
        done = run({
            "collectedAt": "2026-11-04T12:00:00Z",
            "tenantId": "tenant-fixture",
            "collectedBy": "reader@example.invalid",
            "delegated": [
                {"client": "Contoso Mailer", "clientType": "Application", "resource": "Microsoft Graph",
                 "scopes": ["Files.ReadWrite.All", "Mail.Send"]},
            ],
            "application": [
                {"client": "Example Connector", "clientType": "Application", "resource": "Microsoft Graph",
                 "role": "Directory.ReadWrite.All"},
            ],
        })
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("## Delegated grants (AllPrincipals) — 1", done.stdout)
        self.assertIn("| Contoso Mailer | Microsoft Graph | `Files.ReadWrite.All`, `Mail.Send` |", done.stdout)
        self.assertIn("## Application permissions (Microsoft Graph, Exchange Online) — 1", done.stdout)
        self.assertIn("| Example Connector | Microsoft Graph | `Directory.ReadWrite.All` |", done.stdout)

    def test_empty_lists_render_none(self) -> None:
        done = run({"delegated": [], "application": []})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("## Delegated grants (AllPrincipals) — 0", done.stdout)
        self.assertIn("None.", done.stdout)

    def test_a_pipe_in_a_name_cannot_break_the_table(self) -> None:
        done = run({"delegated": [{"client": "A|B", "resource": "Graph", "scopes": ["openid"]}], "application": []})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("| A\\|B | Graph | `openid` |", done.stdout)

    def test_unusable_input_fails(self) -> None:
        for payload in ({"nope": 1}, []):
            done = run(payload)
            self.assertEqual(done.returncode, 2)
            self.assertIn("not a tenant-consents.json", done.stderr)

    def test_missing_file_fails(self) -> None:
        done = subprocess.run([sys.executable, str(REPORT), "/nonexistent/tenant-consents.json"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        self.assertIn("cannot read", done.stderr)


if __name__ == "__main__":
    unittest.main()
