#!/usr/bin/env python3
"""Offline tests for scripts/prune_dead_rova_alerts.py.

Stdlib only. A local HTTP server stands in for Grafana, so the code paths that
touch the SLO plugin's API are exercised with the REAL paths. The 2026-11-06
owner dry run failed because the script called the core API
(`/api/v1/slo`, 404) instead of the SLO plugin resource API — these tests pin
that exact regression.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).with_name("prune_dead_rova_alerts.py")

RULES = [
    {
        "title": title,
        "uid": f"uid-{index}",
        "folderUID": "efwpy0l5x8nwgb",
        "ruleGroup": "rova (production)",
    }
    for index, title in enumerate(
        [
            "rova-production-auth-login-failure-rate",
            "rova-production-db-pool-contention",
            "rova-production-http-5xx-rate",
            "rova-production-http-p99-latency",
            "rova-production-http-slow-request-count",
            "rova-production-worker-job-failure-rate",
        ]
    )
]

DASHBOARDS = {
    "rova-overview-production": "Overview (production)",
    "rova-runtime-production": "Runtime & Dependencies (production)",
}


class Stub(BaseHTTPRequestHandler):
    calls: list[tuple[str, str]] = []
    dashboard_titles = dict(DASHBOARDS)
    rules = list(RULES)
    backup_dir: str | None = None
    backups_at_first_delete: int | None = None

    def log_message(self, *args):  # quiet
        pass

    def _send(self, code: int, payload: object = None) -> None:
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        type(self).calls.append(("GET", self.path))
        if self.path == "/api/v1/provisioning/alert-rules":
            return self._send(200, type(self).rules)
        if self.path == "/api/plugins/grafana-slo-app/resources/v1/slo":
            return self._send(
                200, {"slos": [{"name": "HTTP availability (production)", "uuid": "slo-1"}]}
            )
        for uid, title in type(self).dashboard_titles.items():
            if self.path == f"/api/dashboards/uid/{uid}":
                return self._send(200, {"dashboard": {"uid": uid, "title": title}})
        return self._send(404, {"message": "not found"})

    def do_DELETE(self) -> None:  # noqa: N802
        type(self).calls.append(("DELETE", self.path))
        if type(self).backups_at_first_delete is None and type(self).backup_dir:
            type(self).backups_at_first_delete = len(
                list(Path(type(self).backup_dir).glob("*.json"))
            )
        return self._send(200, {})


def run(server: ThreadingHTTPServer, tmpdir: str, *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["GRAFANA_URL"] = f"http://127.0.0.1:{server.server_port}"
    env["GRAFANA_DELETE_TOKEN"] = "test-token"
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        env=env,
        cwd=tmpdir,
        check=False,
    )


class PruneTests(unittest.TestCase):
    def setUp(self) -> None:
        Stub.calls = []
        Stub.dashboard_titles = dict(DASHBOARDS)
        Stub.rules = list(RULES)
        Stub.backups_at_first_delete = None
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.tmp = tempfile.TemporaryDirectory()
        Stub.backup_dir = self.tmp.name
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.tmp.cleanup)

    def test_dry_run_uses_the_slo_plugin_path_and_deletes_nothing(self) -> None:
        result = run(self.server, self.tmp.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry run: nothing changed", result.stdout)
        gets = [path for method, path in Stub.calls if method == "GET"]
        self.assertIn("/api/plugins/grafana-slo-app/resources/v1/slo", gets)
        self.assertNotIn("/api/v1/slo", gets)
        self.assertFalse([c for c in Stub.calls if c[0] == "DELETE"])
        self.assertIn("delete dashboard Overview (production)", result.stdout)

    def test_apply_deletes_all_pinned_objects_and_saves_backups(self) -> None:
        result = run(
            self.server,
            self.tmp.name,
            "--apply",
            "--confirm",
            "DELETE rova (production)",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        deletes = [path for method, path in Stub.calls if method == "DELETE"]
        self.assertEqual(len([p for p in deletes if p.startswith("/api/v1/provisioning/alert-rules/")]), 6)
        self.assertIn("/api/plugins/grafana-slo-app/resources/v1/slo/slo-1", deletes)
        self.assertIn("/api/dashboards/uid/rova-overview-production", deletes)
        self.assertIn("/api/dashboards/uid/rova-runtime-production", deletes)
        # FOUR backups (rules group, SLO, 2 dashboards) and they exist BEFORE
        # the first DELETE — the irreversible rule/SLO deletes included.
        backups = sorted(Path(self.tmp.name).glob("*.json"))
        self.assertEqual(len(backups), 4, backups)
        self.assertGreaterEqual(Stub.backups_at_first_delete or 0, 4)
        self.assertTrue(any(b.name.startswith("rules-rova-production-") for b in backups))
        self.assertTrue(any(b.name.startswith("slo-slo-1-") for b in backups))

    def test_title_mismatch_refuses_before_any_delete(self) -> None:
        Stub.dashboard_titles["rova-runtime-production"] = "Somebody Else's Board"
        result = run(
            self.server,
            self.tmp.name,
            "--apply",
            "--confirm",
            "DELETE rova (production)",
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("REFUSING", result.stderr)
        self.assertFalse([c for c in Stub.calls if c[0] == "DELETE"])


    def test_partial_resume_with_rules_already_gone(self) -> None:
        """A rerun after the rules were deleted must finish the rest."""
        Stub.rules = []
        result = run(
            self.server,
            self.tmp.name,
            "--apply",
            "--confirm",
            "DELETE rova (production)",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("resume path", result.stdout)
        deletes = [path for method, path in Stub.calls if method == "DELETE"]
        self.assertFalse(any("provisioning/alert-rules" in p for p in deletes))
        self.assertIn("/api/plugins/grafana-slo-app/resources/v1/slo/slo-1", deletes)
        self.assertEqual(
            len([p for p in deletes if p.startswith("/api/dashboards/uid/")]), 2
        )

    def test_mixed_ruleset_refuses(self) -> None:
        Stub.rules = list(RULES)[:5]
        result = run(
            self.server,
            self.tmp.name,
            "--apply",
            "--confirm",
            "DELETE rova (production)",
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("neither the pinned six nor empty", result.stderr)
        self.assertFalse([c for c in Stub.calls if c[0] == "DELETE"])


if __name__ == "__main__":
    unittest.main()
