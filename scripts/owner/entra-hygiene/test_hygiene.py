"""Tests for hygiene.py against an in-memory Graph and AWS. No tenant, no AWS account, no network."""

import datetime as dt
import json
import os
import re
import subprocess
import tempfile
import unittest
import urllib.parse
from types import SimpleNamespace

import hygiene
from hygiene import GraphError, Hygiene, PRODUCTS

NOW = dt.datetime(2026, 10, 18, 9, 0, tzinfo=dt.timezone.utc)
SECRET = "S3cret-VALUE-must-never-print"
OLD_SECRET = "previous-VALUE-must-never-print"
ROVA_DEV = PRODUCTS[("rova", "dev")]


def decoded(url):
    return urllib.parse.unquote(url)


class FakeTenant:
    """Answers the Graph calls hygiene.py makes, from a small state dict, and records every write."""

    def __init__(self):
        self.app = {
            "id": "app-obj",
            "appId": "app-id",
            "displayName": "Rova Dev",
            "notes": "",
            "appRoles": [],
            "passwordCredentials": [{"keyId": "old-key", "endDateTime": "2026-12-01T00:00:00Z"}],
            "servicePrincipalLockConfiguration": None,
        }
        self.sp = {"id": "sp-obj", "appId": "app-id", "appRoleAssignmentRequired": False}
        self.groups = {
            "rova-users": {"id": "g-users", "members": ["u-staff"]},
            "vendors-rova": {"id": "g-vendors", "members": ["u-guest-ok"]},
        }
        self.assignments = []
        self.signins = []
        self.writes = []

    def handle(self, method, url, body=None, allow_missing=False):
        u = decoded(url)
        if method == "GET":
            if "applications?$filter" in u:
                name = re.search(r"displayName eq '(.*?)'", u).group(1)
                return {"value": [self.app] if name == self.app["displayName"] else []}
            if "applications/app-obj?" in u:
                return dict(self.app)
            if "servicePrincipals(appId='app-id')" in u:
                return dict(self.sp)
            if "appRoleAssignedTo" in u:
                return {"value": list(self.assignments)}
            if "groups?$filter" in u:
                name = re.search(r"displayName eq '(.*?)'", u).group(1)
                group = self.groups.get(name)
                return {"value": [{"id": group["id"], "displayName": name}] if group else []}
            if "/members" in u:
                gid = re.search(r"groups/(.*?)/members", u).group(1)
                members = next(g["members"] for g in self.groups.values() if g["id"] == gid)
                return {"value": [{"id": m} for m in members]}
            if "auditLogs/signIns" in u:
                return {"value": list(self.signins)}
            raise AssertionError(f"unexpected GET {u}")
        self.writes.append((method, u, body))
        if method == "POST" and u.endswith("addPassword"):
            self.app["passwordCredentials"].append({"keyId": "new-key", "endDateTime": "2027-04-16T00:00:00Z"})
            return {"keyId": "new-key", "endDateTime": "2027-04-16T00:00:00Z", "secretText": SECRET}
        if method == "POST" and u.endswith("removePassword"):
            key = body["keyId"]
            self.app["passwordCredentials"] = [c for c in self.app["passwordCredentials"] if c["keyId"] != key]
            return None
        if method == "PATCH" and "servicePrincipals/sp-obj" in u:
            self.sp.update(body)
            return None
        if method == "PATCH" and "applications/app-obj" in u:
            self.app.update(body)
            return None
        if method == "POST" and u.endswith("appRoleAssignedTo"):
            self.assignments.append({"principalId": body["principalId"], "appRoleId": body["appRoleId"]})
            return None
        if method == "POST" and u.endswith("/groups"):
            return {"id": "g-new"}
        raise AssertionError(f"unexpected {method} {u}")


class FakeGraph:
    def __init__(self, tenant):
        self.tenant = tenant

    def call(self, method, url, body=None, allow_missing=False):
        return self.tenant.handle(method, url, body, allow_missing)

    def all(self, url):
        return self.tenant.handle("GET", url).get("value", [])


class FakeAws:
    def __init__(self, bundle):
        self.secrets = {"rova/dev/app": json.dumps(bundle)}
        self.events = []
        self.fail_put = False

    def get_secret(self, secret_id):
        return self.secrets[secret_id]

    def put_secret(self, secret_id, text):
        if self.fail_put:
            raise hygiene.AwsError("put failed")
        self.events.append(("put", secret_id))
        self.secrets[secret_id] = text

    def restart(self, cluster, service):
        self.events.append(("restart", service))

    def wait_stable(self, cluster, service):
        self.events.append(("stable", service))


def make(tenant=None, aws=None, answers=None, out=None):
    tenant = tenant or FakeTenant()
    aws = aws or FakeAws({"entra-client-secret": OLD_SECRET, "other": "x"})
    replies = answers or {}
    lines = out if out is not None else []

    def ask(question):
        for fragment, reply in replies.items():
            if fragment in question:
                return reply
        return "y"

    h = Hygiene(FakeGraph(tenant), aws, ask=ask, out=lines.append, now=lambda: NOW, sleep=lambda s: None)
    return h, tenant, aws, lines


class CheckTests(unittest.TestCase):
    def test_lists_signed_in_user_outside_every_group_and_only_them(self):
        tenant = FakeTenant()
        tenant.signins = [
            {"userId": "u-staff", "userPrincipalName": "staff@example.invalid", "status": {"errorCode": 0}},
            {"userId": "u-guest-ok", "userPrincipalName": "ok@example.invalid", "status": {"errorCode": 0}},
            {"userId": "u-stranger", "userPrincipalName": "stranger@example.invalid", "status": {"errorCode": 0}},
        ]
        h, _, _, lines = make(tenant)
        self.assertEqual(h.lost_access(ROVA_DEV), ["stranger@example.invalid"])
        self.assertTrue(any("WOULD LOSE ACCESS: stranger@example.invalid" in line for line in lines))

    def test_failed_sign_ins_do_not_count_as_users(self):
        tenant = FakeTenant()
        tenant.signins = [{"userId": "u-stranger", "userPrincipalName": "x@example.invalid", "status": {"errorCode": 50105}}]
        h, _, _, _ = make(tenant)
        self.assertEqual(h.lost_access(ROVA_DEV), [])

    def test_direct_user_assignment_counts_as_allowed(self):
        tenant = FakeTenant()
        tenant.assignments = [{"principalId": "u-stranger", "principalType": "User", "appRoleId": hygiene.DEFAULT_ROLE_ID}]
        tenant.signins = [{"userId": "u-stranger", "userPrincipalName": "x@example.invalid", "status": {"errorCode": 0}}]
        h, _, _, _ = make(tenant)
        self.assertEqual(h.lost_access(ROVA_DEV), [])


class EnforceTests(unittest.TestCase):
    def test_refuses_to_require_assignment_while_someone_would_lose_access(self):
        tenant = FakeTenant()
        tenant.signins = [{"userId": "u-stranger", "userPrincipalName": "x@example.invalid", "status": {"errorCode": 0}}]
        h, _, _, _ = make(tenant)
        with self.assertRaises(GraphError):
            h.enforce(ROVA_DEV, True)
        self.assertFalse(tenant.sp["appRoleAssignmentRequired"])
        self.assertFalse(any(w[0] == "PATCH" for w in tenant.writes))

    def test_sets_required_when_nobody_would_lose_access(self):
        h, tenant, _, _ = make()
        h.enforce(ROVA_DEV, True)
        self.assertTrue(tenant.sp["appRoleAssignmentRequired"])

    def test_rollback_turns_requirement_off_without_checking(self):
        tenant = FakeTenant()
        tenant.sp["appRoleAssignmentRequired"] = True
        tenant.signins = [{"userId": "u-stranger", "userPrincipalName": "x@example.invalid", "status": {"errorCode": 0}}]
        h, _, _, _ = make(tenant)
        h.enforce(ROVA_DEV, False)
        self.assertFalse(tenant.sp["appRoleAssignmentRequired"])


class RotateTests(unittest.TestCase):
    def rotate(self, **kw):
        h, tenant, aws, lines = make(**kw)
        with tempfile.TemporaryDirectory() as out_dir:
            code = h.rotate(ROVA_DEV, "cluster-x", ["api", "worker"], out_dir)
            calendars = [f for f in os.listdir(out_dir) if f.endswith(".ics")]
            ics = ""
            if calendars:
                with open(os.path.join(out_dir, calendars[0]), encoding="utf-8") as fh:
                    ics = fh.read()
        return code, tenant, aws, lines, ics

    def test_happy_path_removes_old_key_only_after_verified_sign_in(self):
        tenant = FakeTenant()
        tenant.signins = [{"userId": "u-staff", "status": {"errorCode": 0}}]
        code, tenant, aws, _, _ = self.rotate(tenant=tenant)
        self.assertEqual(code, 0)
        remaining = [c["keyId"] for c in tenant.app["passwordCredentials"]]
        self.assertEqual(remaining, ["new-key"])
        removes = [w for w in tenant.writes if w[1].endswith("removePassword")]
        self.assertEqual([w[2]["keyId"] for w in removes], ["old-key"])
        self.assertEqual(json.loads(aws.secrets["rova/dev/app"])["entra-client-secret"], SECRET)
        self.assertEqual(json.loads(aws.secrets["rova/dev/app"])["other"], "x")

    def test_old_key_kept_when_sign_in_never_shows_up(self):
        code, tenant, aws, _, _ = self.rotate(answers={"Did sign-in work": "y"})
        self.assertEqual(code, 1)
        remaining = [c["keyId"] for c in tenant.app["passwordCredentials"]]
        self.assertIn("old-key", remaining)
        self.assertNotIn("new-key", remaining)
        self.assertEqual(json.loads(aws.secrets["rova/dev/app"])["entra-client-secret"], OLD_SECRET)
        self.assertEqual([e for e in aws.events if e[0] == "restart"][-2:], [("restart", "api"), ("restart", "worker")])

    def test_failed_bundle_write_removes_the_new_secret(self):
        tenant = FakeTenant()
        aws = FakeAws({"entra-client-secret": OLD_SECRET})
        aws.fail_put = True
        h, tenant, _, _ = make(tenant=tenant, aws=aws)
        with self.assertRaises(hygiene.AwsError):
            h.rotate(ROVA_DEV, "c", ["api"], tempfile.mkdtemp())
        self.assertEqual([c["keyId"] for c in tenant.app["passwordCredentials"]], ["old-key"])

    def test_secret_value_never_printed(self):
        tenant = FakeTenant()
        tenant.signins = [{"userId": "u-staff", "status": {"errorCode": 0}}]
        _, _, _, lines, ics = self.rotate(tenant=tenant)
        printed = "\n".join(lines)
        self.assertNotIn(SECRET, printed)
        self.assertNotIn(OLD_SECRET, printed)
        self.assertNotIn(SECRET, ics)

    def test_calendar_is_thirty_days_before_expiry(self):
        tenant = FakeTenant()
        tenant.signins = [{"userId": "u-staff", "status": {"errorCode": 0}}]
        _, _, _, _, ics = self.rotate(tenant=tenant)
        self.assertIn("DTSTART;VALUE=DATE:20270317", ics)  # expiry 2027-04-16 minus 30 days


class AwsClientTests(unittest.TestCase):
    def test_secret_travels_on_stdin_and_profile_is_named(self):
        seen = {}

        def runner(cmd, input=None, capture_output=None, text=None):
            seen["cmd"], seen["input"] = cmd, input
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        hygiene.AwsClient(runner).put_secret("rova/dev/app", SECRET)
        self.assertNotIn(SECRET, " ".join(seen["cmd"]))
        self.assertEqual(seen["input"], SECRET)
        self.assertIn("file:///dev/stdin", seen["cmd"])
        self.assertEqual(seen["cmd"][seen["cmd"].index("--profile") + 1], "qnsc-admin")


class GraphClientTests(unittest.TestCase):
    def test_throttled_call_is_retried(self):
        replies = [
            SimpleNamespace(returncode=1, stdout="", stderr="(429) TooManyRequests"),
            SimpleNamespace(returncode=0, stdout='{"ok": true}', stderr=""),
        ]
        client = hygiene.GraphClient(runner=lambda *a, **k: replies.pop(0), sleep=lambda s: None)
        self.assertEqual(client.call("GET", "https://example.invalid"), {"ok": True})

    def test_missing_service_principal_returns_none_when_allowed(self):
        client = hygiene.GraphClient(
            runner=lambda *a, **k: SimpleNamespace(returncode=1, stdout="", stderr="Request_ResourceNotFound"),
            sleep=lambda s: None,
        )
        self.assertIsNone(client.call("GET", "https://example.invalid", allow_missing=True))
        with self.assertRaises(GraphError):
            client.call("GET", "https://example.invalid")


class NotesAndGroupTests(unittest.TestCase):
    def test_existing_notes_are_kept_without_force(self):
        tenant = FakeTenant()
        tenant.app["notes"] = "someone wrote this"
        h, tenant, _, _ = make(tenant)
        h.notes(force=False)
        self.assertFalse(any(w[0] == "PATCH" for w in tenant.writes))

    def test_dynamic_group_cannot_take_manual_members(self):
        h, _, _, _ = make()
        with self.assertRaises(GraphError):
            h.add_member(ROVA_DEV, "rova-users", "a@example.invalid")

    def test_dynamic_group_is_created_with_member_rule(self):
        h, tenant, _, _ = make()
        group = next(g for g in ROVA_DEV.groups if g.dynamic)
        tenant.groups.pop(group.name)
        h.ensure_group(group)
        body = [w[2] for w in tenant.writes if w[1].endswith("/groups")][0]
        self.assertEqual(body["membershipRule"], hygiene.MEMBER_RULE)
        self.assertEqual(body["groupTypes"], ["DynamicMembership"])


if __name__ == "__main__":
    unittest.main()
