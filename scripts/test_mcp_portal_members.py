#!/usr/bin/env python3
"""Offline tests for scripts/edge/mcp-portal-members.sh.

Stdlib only. A local HTTP server stands in for the Cloudflare API on the REAL path
(/client/v4/accounts/<id>/access/ai-controls/mcp/portals/<id>), so the exact URLs and the
portal body shape are exercised with no credential and no network.

What is pinned (the reason the script exists): provider 5.28.1 cannot apply portal
membership because it PUTs `updated_tools: null`. The script must therefore:
  * ADD a missing server while sending every Cloudflare-filled field of the existing
    entries back unchanged (the updated_tools round-trip);
  * be a NO-OP when membership already matches (no PUT at all);
  * FAIL when the API does not end up with the desired membership.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "edge" / "mcp-portal-members.sh"

ROVA_DEV = {
    "server_id": "rova-dev",
    "on_behalf": True,
    "default_disabled": False,
    "updated_tools": [
        {"name": "rova_search", "enabled": True, "alias": "search", "description": "Search rova"},
        {"name": "rova_issue", "enabled": False},
    ],
    "updated_prompts": [{"name": "rova_plan", "enabled": True}],
}
KB_PROD = {"server_id": "kb-prod", "on_behalf": True}

PORTAL = {
    "id": "qnsc",
    "name": "qnsc",
    "hostname": "portal.example.test",
    "description": "QNSC MCP server portal",
    "created_at": "2026-10-24T00:00:00Z",
    "updated_at": "2026-11-06T00:00:00Z",
    "servers": [dict(ROVA_DEV)],
}


class Stub(BaseHTTPRequestHandler):
    calls: list[tuple[str, str]] = []
    portal: dict = {}
    apply_put = True
    # Set to a float when the GET should fail with 500.
    fail_get = False

    def log_message(self, *args):  # quiet
        pass

    def _send(self, code: int, payload: object) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        type(self).calls.append(("GET", self.path))
        if type(self).fail_get:
            return self._send(500, {"success": False, "errors": [{"code": 1, "message": "boom"}]})
        assert self.path == "/client/v4/accounts/acct-1/access/ai-controls/mcp/portals/qnsc", self.path
        return self._send(200, {"success": True, "result": type(self).portal})

    def do_PUT(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        type(self).calls.append(("PUT", self.path))
        assert self.path == "/client/v4/accounts/acct-1/access/ai-controls/mcp/portals/qnsc", self.path
        assert self.headers.get("Authorization") == "Bearer test-token"
        if type(self).apply_put:
            type(self).portal = {**type(self).portal, **body}
        return self._send(200, {"success": True, "result": type(self).portal})


class PortalMembersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}/client/v4"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self) -> None:
        Stub.calls = []
        Stub.portal = json.loads(json.dumps(PORTAL))
        Stub.apply_put = True
        Stub.fail_get = False

    def run_script(self, servers: list[dict]) -> subprocess.CompletedProcess:
        env = {
            **os.environ,
            "CLOUDFLARE_API_TOKEN": "test-token",
            "CLOUDFLARE_ACCOUNT_ID": "acct-1",
            "MCP_PORTAL_ID": "qnsc",
            "MCP_PORTAL_SERVERS": json.dumps(servers),
            "CLOUDFLARE_API_BASE": self.base,
        }
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_add_preserves_updated_tools(self) -> None:
        want = [{"server_id": "rova-dev", "on_behalf": True}, KB_PROD]
        result = self.run_script(want)
        self.assertEqual(result.returncode, 0, result.stderr)

        puts = [path for method, path in Stub.calls if method == "PUT"]
        self.assertEqual(len(puts), 1, "one PUT for the new membership")

        by_id = {s["server_id"]: s for s in Stub.portal["servers"]}
        self.assertEqual(set(by_id), {"rova-dev", "kb-prod"})
        # updated_tools/updated_prompts/default_disabled survive the round-trip untouched.
        self.assertEqual(by_id["rova-dev"]["updated_tools"], ROVA_DEV["updated_tools"])
        self.assertEqual(by_id["rova-dev"]["updated_prompts"], ROVA_DEV["updated_prompts"])
        self.assertFalse(by_id["rova-dev"]["default_disabled"])
        self.assertTrue(by_id["kb-prod"]["on_behalf"])
        # Every non-servers field of the portal body came from the GET unchanged.
        for key in ("id", "name", "hostname", "description", "created_at", "updated_at"):
            self.assertEqual(Stub.portal[key], PORTAL[key], key)

    def test_noop_when_membership_matches(self) -> None:
        want = [{"server_id": "rova-dev", "on_behalf": True}]
        result = self.run_script(want)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no PUT", result.stdout)
        self.assertEqual([m for m, _ in Stub.calls], ["GET"], "GET only, no PUT")

    def test_updated_tools_round_trip_on_membership_change(self) -> None:
        # Removing a server is also a membership change: the surviving entry must still carry
        # its Cloudflare-filled updated_tools exactly as the GET returned them.
        Stub.portal["servers"] = [dict(ROVA_DEV), {"server_id": "old-server", "on_behalf": True}]
        want = [{"server_id": "rova-dev", "on_behalf": True}]
        result = self.run_script(want)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([s["server_id"] for s in Stub.portal["servers"]], ["rova-dev"])
        self.assertEqual(Stub.portal["servers"][0]["updated_tools"], ROVA_DEV["updated_tools"])

    def test_fails_when_api_does_not_apply(self) -> None:
        Stub.apply_put = False
        result = self.run_script([{"server_id": "rova-dev", "on_behalf": True}, KB_PROD])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("membership after PUT", result.stderr)

    def test_fails_on_get_error(self) -> None:
        Stub.fail_get = True
        result = self.run_script([{"server_id": "rova-dev", "on_behalf": True}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not succeed", result.stderr)

    def test_refuses_empty_desired_list(self) -> None:
        result = self.run_script([])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to empty the portal", result.stderr)
        self.assertEqual(Stub.calls, [], "no API call before the guard")


if __name__ == "__main__":
    unittest.main(verbosity=2)
