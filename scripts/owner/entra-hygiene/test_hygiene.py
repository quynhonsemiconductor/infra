"""Tests for hygiene.py against in-memory Graph, AWS and ECS. No tenant, no AWS account, no network."""

import contextlib
import datetime as dt
import io
import json
import os
import re
import tempfile
import unittest
import urllib.parse
from types import SimpleNamespace

import hygiene
from hygiene import DEFAULT_ROLE_ID, GraphError, Group, Hygiene, MEMBER_RULE, PRODUCTS

NOW = dt.datetime(2026, 10, 18, 9, 0, tzinfo=dt.timezone.utc)
ACCOUNT = "608983206583"
ROVA_DEV = PRODUCTS[("rova", "develop")]
ROVA_PROD = PRODUCTS[("rova", "production")]
KB_DEV = PRODUCTS[("kb", "develop")]
OPSHUB_DEV = PRODUCTS[("opshub", "develop")]
PREV = "preVALUE-must-never-print"  # the value in the bundle; its first three characters are the hint "pre"
SECRET = "newVALUE-must-never-print"  # what addPassword returns; hint "new"
OPERATOR = "operator@example.invalid"
P1_SKU = {"consumedUnits": 5, "servicePlans": [{"servicePlanName": "AAD_PREMIUM", "provisioningStatus": "Success"}]}
DEFAULT_CREDS = [{"keyId": "old-key", "hint": "pre"}, {"keyId": "other-key", "hint": "zzz"}]


def decoded(url):
    return urllib.parse.unquote(url)


class Missing(Exception):
    pass


class FakeTenant:
    def __init__(self, app_name="Rova Dev", app_roles=None):
        self.app = {
            "id": "app-obj",
            "appId": "app-id",
            "displayName": app_name,
            "notes": "",
            "appRoles": list(app_roles or []),
            "passwordCredentials": [dict(c) for c in DEFAULT_CREDS],
            "servicePrincipalLockConfiguration": None,
        }
        self.sp = {"id": "sp-obj", "appId": "app-id", "appRoleAssignmentRequired": False}
        self.groups: dict[str, dict] = {}
        self.assignments: list[dict] = []
        self.signins: list[dict] = []
        self.skus = [P1_SKU]
        self.users: list[dict] = []
        self.writes: list[tuple] = []
        self.signin_read_denied = False

    def group(self, name, gid, dynamic=False, members=(), description=hygiene.GROUP_DESCRIPTION):
        self.groups[name] = {
            "id": gid,
            "displayName": name,
            "groupTypes": ["DynamicMembership"] if dynamic else [],
            "membershipRule": MEMBER_RULE if dynamic else None,
            "description": description,
            "securityEnabled": True,
            "mailEnabled": False,
            "members": list(members),
        }

    def signin(self, upn, uid=None, error=0):
        self.signins.append({"userId": uid or upn, "userPrincipalName": upn, "status": {"errorCode": error}})

    def handle(self, method, url, body=None):
        u = decoded(url)
        if method == "GET":
            return self.read(u)
        self.writes.append((method, u, body))
        return self.write(method, u, body)

    def read(self, u):
        if "auditLogs/signIns" in u:
            if "$top=1" in u and "$filter" not in u:
                if self.signin_read_denied:
                    raise GraphError("(Forbidden) Insufficient privileges")
                return {"value": []}
            items = list(self.signins)
            m = re.search(r"userPrincipalName eq '(.*?)'", u)
            if m:
                items = [s for s in items if s["userPrincipalName"] == m.group(1)]
            return {"value": items}
        if "subscribedSkus" in u:
            return {"value": self.skus}
        if u.endswith("/me?$select=userPrincipalName"):
            return {"userPrincipalName": OPERATOR}
        if "users?$filter" in u:
            value = re.search(r"'(.*?)'", u).group(1)
            return {"value": [x for x in self.users if value in (x["userPrincipalName"], x.get("mail"), *x.get("otherMails", []))]}
        if "/users/" in u:
            upn = u.split("/users/", 1)[1].split("?", 1)[0]
            for x in self.users:
                if x["userPrincipalName"] == upn:
                    return dict(x)
            raise Missing()
        if "applications?$filter" in u:
            name = re.search(r"displayName eq '(.*?)'", u).group(1)
            return {"value": [self.app] if name == self.app["displayName"] else []}
        if "applications/app-obj?" in u:
            return json.loads(json.dumps(self.app))
        if "servicePrincipals(appId='app-id')" in u:
            return dict(self.sp)
        if "servicePrincipals(appId=" in u:
            raise Missing()
        if "appRoleAssignedTo" in u:
            return {"value": [dict(a) for a in self.assignments]}
        if "groups?$filter" in u:
            name = re.search(r"displayName eq '(.*?)'", u).group(1)
            group = self.groups.get(name)
            return {"value": [dict(group)] if group else []}
        if "/members?" in u:
            gid = re.search(r"groups/([^/]+)/members", u).group(1)
            return {"value": [{"id": m} for g in self.groups.values() if g["id"] == gid for m in g["members"]]}
        raise AssertionError(f"unexpected GET {u}")

    def write(self, method, u, body):
        if method == "POST" and u.endswith("addPassword"):
            new = {"keyId": "new-key", "hint": SECRET[:3], "endDateTime": "2027-04-16T00:00:00Z", "secretText": SECRET}
            self.app["passwordCredentials"].append({"keyId": "new-key", "hint": SECRET[:3]})
            return dict(new)
        if method == "POST" and u.endswith("removePassword"):
            self.app["passwordCredentials"] = [c for c in self.app["passwordCredentials"] if c["keyId"] != body["keyId"]]
            return None
        if method == "PATCH" and u.endswith("servicePrincipals/sp-obj"):
            self.sp.update(body)
            return None
        if method == "PATCH" and u.endswith("applications/app-obj"):
            self.app.update(body)
            return None
        if method == "POST" and u.endswith("sp-obj/appRoleAssignedTo"):
            self.assignments.append({"principalId": body["principalId"], "principalType": "Group", "appRoleId": body["appRoleId"]})
            return None
        if method == "POST" and u.endswith("/groups"):
            self.group(body["displayName"], "g-new", dynamic="DynamicMembership" in body["groupTypes"], description=body["description"])
            return {"id": "g-new"}
        if method == "POST" and u.endswith("/members/$ref"):
            gid = re.search(r"groups/([^/]+)/members", u).group(1)
            member = body["@odata.id"].rsplit("/", 1)[-1]
            for g in self.groups.values():
                if g["id"] == gid:
                    g["members"].append(member)
            return None
        raise AssertionError(f"unexpected write {method} {u}")


class FakeGraph:
    def __init__(self, tenant):
        self.tenant = tenant

    def call(self, method, url, body=None, allow_missing=False, headers=()):
        try:
            return self.tenant.handle(method, url, body)
        except Missing:
            if allow_missing:
                return None
            raise GraphError("Request_ResourceNotFound")

    def all(self, url, headers=()):
        return self.tenant.handle("GET", url).get("value", [])


class FakeAws:
    def __init__(self, bundle_id, bundle):
        self.bundle_id = bundle_id
        self.secrets = {bundle_id: json.dumps(bundle)}
        self.events: list[tuple] = []
        self.services: dict[str, dict] = {}
        self.task_defs: dict[str, dict] = {}
        self.fail_put = False
        self.corrupt_put = False
        self.rollout_broken = False

    def add_service(self, name, via="secrets", key="entra-client-secret"):
        ref = f"arn:aws:secretsmanager:ap-southeast-1:{ACCOUNT}:secret:{self.bundle_id}-AbCdEf"
        container = {"secrets": [{"name": "X", "valueFrom": f"{ref}:{key}::"}]} if via == "secrets" else {"environment": [{"name": "IDENTITY_HOME_SECRET_REF", "value": ref}]}
        self.task_defs[f"td-{name}"] = {"containerDefinitions": [container]}
        self.services[name] = {"serviceName": name, "taskDefinition": f"td-{name}", "deployments": [self.deployment("2026-10-17T00:00:00+00:00", 1)]}

    @staticmethod
    def deployment(created, running):
        return {"status": "PRIMARY", "createdAt": created, "runningCount": running, "desiredCount": 1, "rolloutState": "COMPLETED"}

    def get_secret(self, secret_id):
        return self.secrets[secret_id]

    def put_secret(self, secret_id, text):
        if self.fail_put:
            raise hygiene.AwsError("put failed")
        data = json.loads(text)
        if self.corrupt_put:
            data["other"] = "changed-by-accident"
        self.secrets[secret_id] = json.dumps(data)
        self.events.append(("put", secret_id))

    def list_services(self, cluster):
        return [f"arn:aws:ecs:ap-southeast-1:{ACCOUNT}:service/{cluster}/{n}" for n in self.services]

    def describe_services(self, cluster, names):
        return [json.loads(json.dumps(self.services[n])) for n in names if n in self.services]

    def task_definition(self, arn):
        return self.task_defs[arn]

    def restart(self, cluster, service):
        self.events.append(("restart", service))
        running = 0 if self.rollout_broken else 1
        self.services[service]["deployments"] = [self.deployment("2026-10-18T09:30:00+00:00", running)]

    def wait_stable(self, cluster, service):
        self.events.append(("stable", service))


def make(tenant, aws, answers=None):
    replies = answers or {}
    lines: list[str] = []

    def ask(question):
        for fragment, reply in replies.items():
            if fragment in question:
                return reply
        return "y"

    h = Hygiene(FakeGraph(tenant), aws, ask=ask, out=lines.append, now=lambda: NOW, sleep=lambda s: None)
    return h, lines


def rova_rotation(prod=False):
    bundle_id = "rova/production/app" if prod else "rova/develop/app"
    aws = FakeAws(bundle_id, {"entra-client-secret": PREV, "other": "x"})
    aws.add_service("api")
    aws.add_service("worker")
    tenant = FakeTenant("Rova Prod" if prod else "Rova Dev")
    tenant.signin(OPERATOR)
    return tenant, aws


def run_rotate(tenant, aws, product, services=("api", "worker"), answers=None):
    h, lines = make(tenant, aws, answers)
    out_dir = tempfile.mkdtemp()
    code = h.rotate(product, "cluster-x", list(services), out_dir)
    ics = ""
    for name in os.listdir(out_dir):
        with open(os.path.join(out_dir, name), encoding="utf-8") as fh:
            ics += fh.read()
    return code, lines, ics


def adds(tenant):
    return [w for w in tenant.writes if w[0] == "POST" and w[1].endswith("addPassword")]


def removals(tenant):
    return [w[2]["keyId"] for w in tenant.writes if w[1].endswith("removePassword")]


class RotateTests(unittest.TestCase):
    def test_happy_path_removes_only_the_old_key_after_verified_sign_in(self):
        tenant, aws = rova_rotation()
        code, _, _ = run_rotate(tenant, aws, ROVA_DEV)
        self.assertEqual(code, 0)
        self.assertEqual(removals(tenant), ["old-key"])
        self.assertEqual([c["keyId"] for c in tenant.app["passwordCredentials"]], ["other-key", "new-key"])
        bundle = json.loads(aws.secrets["rova/develop/app"])
        self.assertEqual(bundle, {"entra-client-secret": SECRET, "other": "x"})

    def test_kb_rotates_its_own_key_and_leaves_the_other_untouched(self):
        aws = FakeAws("qnsc-kb/develop/app", {"microsoft-client-secret": PREV, "entra-client-secret": "unrelated"})
        aws.add_service("kb-api", key="microsoft-client-secret")
        tenant = FakeTenant("KB Dev")
        tenant.signin(OPERATOR)
        code, _, _ = run_rotate(tenant, aws, KB_DEV, services=("kb-api",))
        self.assertEqual(code, 0)
        bundle = json.loads(aws.secrets["qnsc-kb/develop/app"])
        self.assertEqual(bundle, {"microsoft-client-secret": SECRET, "entra-client-secret": "unrelated"})

    def test_refuses_before_adding_a_secret_when_the_key_is_missing(self):
        aws = FakeAws("rova/develop/app", {"other": "x"})
        aws.add_service("api")
        tenant = FakeTenant()
        with self.assertRaises(GraphError):
            run_rotate(tenant, aws, ROVA_DEV, services=("api",))
        self.assertEqual(adds(tenant), [])

    def test_refuses_before_adding_a_secret_when_a_consumer_is_not_listed(self):
        tenant, aws = rova_rotation()
        aws.add_service("ingest", via="env")
        with self.assertRaises(GraphError) as ctx:
            run_rotate(tenant, aws, ROVA_DEV, services=("api", "worker"))
        self.assertIn("ingest", str(ctx.exception))
        self.assertEqual(adds(tenant), [])

    def test_env_injected_consumer_is_found(self):
        tenant, aws = rova_rotation()
        aws.add_service("ingest", via="env")
        code, _, _ = run_rotate(tenant, aws, ROVA_DEV, services=("api", "worker", "ingest"))
        self.assertEqual(code, 0)

    def test_empty_service_list_is_refused(self):
        tenant, aws = rova_rotation()
        with self.assertRaises(GraphError) as ctx:
            run_rotate(tenant, aws, ROVA_DEV, services=())
        self.assertIn("--services is empty", str(ctx.exception))
        self.assertEqual(adds(tenant), [])

    def test_ambiguous_hint_is_refused_before_writing(self):
        tenant, aws = rova_rotation()
        tenant.app["passwordCredentials"].append({"keyId": "dup-key", "hint": "pre"})
        with self.assertRaises(GraphError):
            run_rotate(tenant, aws, ROVA_DEV)
        self.assertEqual(adds(tenant), [])

    def test_incomplete_rollout_rolls_back_and_keeps_the_old_key(self):
        tenant, aws = rova_rotation()
        aws.rollout_broken = True
        code, _, _ = run_rotate(tenant, aws, ROVA_DEV)
        self.assertEqual(code, 1)
        self.assertEqual(removals(tenant), ["new-key"])
        self.assertEqual(json.loads(aws.secrets["rova/develop/app"])["entra-client-secret"], PREV)

    def test_no_sign_in_by_the_operator_rolls_back(self):
        tenant, aws = rova_rotation()
        tenant.signins = []
        code, _, _ = run_rotate(tenant, aws, ROVA_DEV)
        self.assertEqual(code, 1)
        self.assertNotIn("old-key", removals(tenant))
        self.assertIn("new-key", removals(tenant))

    def test_failed_put_removes_the_new_secret(self):
        tenant, aws = rova_rotation()
        aws.fail_put = True
        with self.assertRaises(hygiene.AwsError):
            run_rotate(tenant, aws, ROVA_DEV)
        self.assertEqual(removals(tenant), ["new-key"])
        self.assertEqual(json.loads(aws.secrets["rova/develop/app"])["entra-client-secret"], PREV)

    def test_put_that_changes_another_key_is_detected_and_undone(self):
        tenant, aws = rova_rotation()
        aws.corrupt_put = True
        with self.assertRaises(hygiene.AwsError):
            run_rotate(tenant, aws, ROVA_DEV)
        self.assertEqual(removals(tenant), ["new-key"])
        self.assertEqual(json.loads(aws.secrets["rova/develop/app"])["entra-client-secret"], PREV)

    def test_secret_value_never_printed_and_calendar_is_thirty_days_before_expiry(self):
        tenant, aws = rova_rotation()
        _, lines, ics = run_rotate(tenant, aws, ROVA_DEV)
        printed = "\n".join(lines)
        for secret in (SECRET, PREV):
            self.assertNotIn(secret, printed)
            self.assertNotIn(secret, ics)
        self.assertIn("DTSTART;VALUE=DATE:20270317", ics)  # expiry 2027-04-16 minus 30 days

    def test_production_needs_the_typed_app_name(self):
        tenant, aws = rova_rotation(prod=True)
        with self.assertRaises(GraphError):
            run_rotate(tenant, aws, ROVA_PROD, answers={"Type the sign-in app name": "Rova Dev"})
        self.assertEqual(adds(tenant), [])

    def test_production_without_prod_flag_is_refused_by_the_cli(self):
        with tempfile.TemporaryDirectory() as out_dir:
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                hygiene.main(
                    ["rotate", "--product", "rova", "--env", "production", "--cluster", "c", "--services", "api", "--out-dir", out_dir],
                    graph=FakeGraph(FakeTenant()),
                    aws=FakeAws("x", {}),
                )


class LostAccessTests(unittest.TestCase):
    def kb_ready(self):
        tenant = FakeTenant("KB Dev")
        tenant.group("kb-users", "g-users", dynamic=True, members=["u-staff"])
        tenant.group("kb-guests", "g-guests", members=["u-guest"])
        tenant.assignments = [
            {"principalId": "g-users", "principalType": "Group", "appRoleId": DEFAULT_ROLE_ID},
            {"principalId": "g-guests", "principalType": "Group", "appRoleId": DEFAULT_ROLE_ID},
        ]
        tenant.users = [
            {"id": "u-staff", "userPrincipalName": "staff@example.invalid"},
            {"id": "u-guest", "userPrincipalName": "guest_x.example.invalid#EXT#@t.onmicrosoft.com", "mail": "guest@x.example.invalid"},
        ]
        return tenant

    def test_lists_a_user_outside_the_groups_and_only_them(self):
        tenant = self.kb_ready()
        tenant.signin("staff@example.invalid", "u-staff")
        tenant.signin("guest_x.example.invalid#EXT#@t.onmicrosoft.com", "u-guest")
        tenant.signin("stranger@example.invalid", "u-stranger")
        h, _ = make(tenant, FakeAws("x", {}))
        self.assertEqual(h.lost_access(KB_DEV), ["stranger@example.invalid"])

    def test_failed_sign_ins_are_not_users(self):
        tenant = self.kb_ready()
        tenant.signins.append({"userId": "u-s", "userPrincipalName": "s@example.invalid", "status": {"errorCode": 50105}})
        h, _ = make(tenant, FakeAws("x", {}))
        self.assertEqual(h.lost_access(KB_DEV), [])

    def test_direct_user_assignment_is_allowed(self):
        tenant = self.kb_ready()
        tenant.assignments.append({"principalId": "u-stranger", "principalType": "User", "appRoleId": DEFAULT_ROLE_ID})
        tenant.users.append({"id": "u-stranger", "userPrincipalName": "stranger@example.invalid"})
        tenant.signin("stranger@example.invalid", "u-stranger")
        h, _ = make(tenant, FakeAws("x", {}))
        self.assertEqual(h.lost_access(KB_DEV), [])

    def test_group_that_exists_but_is_not_assigned_allows_nobody(self):
        tenant = self.kb_ready()
        tenant.assignments = [a for a in tenant.assignments if a["principalId"] != "g-guests"]
        h, _ = make(tenant, FakeAws("x", {}))
        with self.assertRaises(GraphError) as ctx:
            h.lost_access(KB_DEV)
        self.assertIn("not assigned", str(ctx.exception))

    def test_enforce_refuses_while_someone_would_lose_access_and_writes_nothing(self):
        tenant = self.kb_ready()
        tenant.signin("stranger@example.invalid", "u-stranger")
        h, _ = make(tenant, FakeAws("x", {}))
        with self.assertRaises(GraphError):
            h.enforce(KB_DEV, True)
        self.assertEqual(tenant.writes, [])

    def test_enforce_and_rollback_set_the_flag(self):
        tenant = self.kb_ready()
        h, _ = make(tenant, FakeAws("x", {}))
        h.enforce(KB_DEV, True)
        self.assertTrue(tenant.sp["appRoleAssignmentRequired"])
        h.enforce(KB_DEV, False)
        self.assertFalse(tenant.sp["appRoleAssignmentRequired"])

    def test_preflight_fails_when_the_sign_in_log_is_not_readable(self):
        tenant = self.kb_ready()
        tenant.signin_read_denied = True
        h, _ = make(tenant, FakeAws("x", {}))
        with self.assertRaises(GraphError):
            h.lost_access(KB_DEV)


class RovaExclusionTests(unittest.TestCase):
    def test_rova_is_refused_by_every_assignment_command(self):
        tenant = FakeTenant()
        h, _ = make(tenant, FakeAws("x", {}))
        for call in (
            lambda: h.setup(ROVA_DEV),
            lambda: h.add_role(ROVA_DEV),
            lambda: h.lost_access(ROVA_DEV),
            lambda: h.enforce(ROVA_DEV, True),
            lambda: h.enforce(ROVA_DEV, False),
            lambda: h.add_member(ROVA_DEV, "kb-guests", "a@example.invalid"),
        ):
            with self.assertRaises(GraphError):
                call()
        self.assertEqual(tenant.writes, [])


class GroupAndRoleTests(unittest.TestCase):
    def test_existing_group_with_other_settings_is_not_reused(self):
        tenant = FakeTenant("KB Dev")
        tenant.group("kb-users", "g-users", dynamic=True, description="someone else's group")
        h, _ = make(tenant, FakeAws("x", {}))
        with self.assertRaises(GraphError):
            h.ensure_group(KB_DEV.groups[0])
        self.assertEqual(tenant.writes, [])

    def test_dynamic_group_rule_excludes_disabled_accounts(self):
        self.assertIn("user.accountEnabled -eq true", MEMBER_RULE)
        tenant = FakeTenant("KB Dev")
        h, _ = make(tenant, FakeAws("x", {}))
        h.ensure_group(next(g for g in KB_DEV.groups if g.dynamic))
        body = [w[2] for w in tenant.writes if w[1].endswith("/groups")][0]
        self.assertEqual(body["membershipRule"], MEMBER_RULE)
        self.assertEqual(body["groupTypes"], ["DynamicMembership"])

    def test_setup_without_p1_is_refused(self):
        tenant = FakeTenant("KB Dev")
        tenant.skus = [{"consumedUnits": 5, "servicePlans": [{"servicePlanName": "EXCHANGE_S", "provisioningStatus": "Success"}]}]
        h, _ = make(tenant, FakeAws("x", {}))
        with self.assertRaises(GraphError):
            h.setup(KB_DEV)
        self.assertEqual(tenant.writes, [])

    def test_opshub_setup_uses_the_employee_role_id(self):
        tenant = FakeTenant("OpsHub Dev", app_roles=[{"id": "role-emp", "value": "employee", "isEnabled": True}])
        h, _ = make(tenant, FakeAws("x", {}))
        h.setup(OPSHUB_DEV)
        self.assertEqual({a["appRoleId"] for a in tenant.assignments}, {"role-emp"})
        self.assertEqual(len(tenant.assignments), 2)

    def test_opshub_setup_stops_when_the_role_is_missing(self):
        tenant = FakeTenant("OpsHub Dev", app_roles=[{"id": "r-x", "value": "admin", "isEnabled": True}])
        h, _ = make(tenant, FakeAws("x", {}))
        with self.assertRaises(GraphError) as ctx:
            h.setup(OPSHUB_DEV)
        self.assertIn("add-role", str(ctx.exception))
        self.assertEqual(tenant.writes, [])

    def test_add_role_keeps_existing_roles_and_adds_employee(self):
        tenant = FakeTenant("OpsHub Dev", app_roles=[{"id": "r-x", "value": "admin", "displayName": "Admin", "isEnabled": True, "allowedMemberTypes": ["User"], "description": "d", "origin": "Application"}])
        h, _ = make(tenant, FakeAws("x", {}))
        h.add_role(OPSHUB_DEV)
        patch = [w for w in tenant.writes if w[0] == "PATCH"][0][2]["appRoles"]
        self.assertEqual([r["value"] for r in patch], ["admin", "employee"])
        self.assertNotIn("origin", patch[0])

    def test_add_role_is_idempotent(self):
        tenant = FakeTenant("OpsHub Dev", app_roles=[{"id": "r-e", "value": "employee", "isEnabled": True}])
        h, _ = make(tenant, FakeAws("x", {}))
        h.add_role(OPSHUB_DEV)
        self.assertEqual(tenant.writes, [])


class MemberTests(unittest.TestCase):
    def test_guest_is_found_by_mail_when_the_upn_lookup_misses(self):
        tenant = FakeTenant("KB Dev")
        tenant.group("kb-guests", "g-guests")
        tenant.users = [{"id": "u-guest", "userPrincipalName": "guest_x.example.invalid#EXT#@t.onmicrosoft.com", "mail": "guest@x.example.invalid"}]
        h, _ = make(tenant, FakeAws("x", {}))
        h.add_member(KB_DEV, "kb-guests", "guest@x.example.invalid")
        self.assertEqual(tenant.groups["kb-guests"]["members"], ["u-guest"])

    def test_dynamic_group_cannot_take_manual_members(self):
        tenant = FakeTenant("KB Dev")
        h, _ = make(tenant, FakeAws("x", {}))
        with self.assertRaises(GraphError):
            h.add_member(KB_DEV, "kb-users", "a@example.invalid")


class GraphClientTests(unittest.TestCase):
    def client(self, replies):
        calls = []

        def runner(args, capture_output=None, text=None):
            calls.append(args)
            return replies.pop(0)

        return hygiene.GraphClient(runner=runner, sleep=lambda s: None), calls

    def test_post_is_retried_on_429(self):
        client, calls = self.client([SimpleNamespace(returncode=1, stdout="", stderr="(429) TooManyRequests"), SimpleNamespace(returncode=0, stdout='{"ok": 1}', stderr="")])
        self.assertEqual(client.call("POST", "https://example.invalid", {"a": 1}), {"ok": 1})
        self.assertEqual(len(calls), 2)

    def test_post_is_not_retried_on_503(self):
        client, calls = self.client([SimpleNamespace(returncode=1, stdout="", stderr="(503) ServiceUnavailable")])
        with self.assertRaises(GraphError):
            client.call("POST", "https://example.invalid", {"a": 1})
        self.assertEqual(len(calls), 1)

    def test_get_is_retried_on_503(self):
        client, calls = self.client([SimpleNamespace(returncode=1, stdout="", stderr="(503) ServiceUnavailable"), SimpleNamespace(returncode=0, stdout="{}", stderr="")])
        client.call("GET", "https://example.invalid")
        self.assertEqual(len(calls), 2)

    def test_missing_resource_is_none_only_when_allowed(self):
        client, _ = self.client([SimpleNamespace(returncode=1, stdout="", stderr="Request_ResourceNotFound")])
        self.assertIsNone(client.call("GET", "https://example.invalid", allow_missing=True))
        client, _ = self.client([SimpleNamespace(returncode=1, stdout="", stderr="Request_ResourceNotFound")])
        with self.assertRaises(GraphError):
            client.call("GET", "https://example.invalid")


class AwsClientTests(unittest.TestCase):
    def test_secret_travels_on_stdin_and_profile_is_named(self):
        seen = {}

        def runner(cmd, input=None, capture_output=None, text=None):
            seen["cmd"], seen["input"] = cmd, input
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        hygiene.AwsClient(runner).put_secret("rova/develop/app", SECRET)
        self.assertNotIn(SECRET, " ".join(seen["cmd"]))
        self.assertEqual(seen["input"], SECRET)
        self.assertIn("file:///dev/stdin", seen["cmd"])
        self.assertEqual(seen["cmd"][seen["cmd"].index("--profile") + 1], "qnsc-admin")


class NotesTests(unittest.TestCase):
    def test_existing_notes_are_kept_without_force(self):
        tenant = FakeTenant()
        tenant.app["notes"] = "someone wrote this"
        h, _ = make(tenant, FakeAws("x", {}))
        h.notes(force=False)
        self.assertFalse(any(w[0] == "PATCH" for w in tenant.writes))


if __name__ == "__main__":
    unittest.main()
