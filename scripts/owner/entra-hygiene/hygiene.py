#!/usr/bin/env python3
"""Owner runbook helper for the Entra sign-in app hygiene track (see README.md next to this file).

Entra calls go through `az rest` with the owner's Entra admin login. AWS calls go through `aws` with
`--profile qnsc-admin`. Secret values exist only in memory and on stdin: never printed, never in argv, never on disk.
Every mutating command prints its plan and asks before writing. On a production env it also asks for the app name.

    python3 hygiene.py status     --product rova --env develop
    python3 hygiene.py setup      --product opshub --env develop
    python3 hygiene.py add-role   --product opshub --env develop      # the App Role "employee" (OpsHub only)
    python3 hygiene.py add-member --product kb --env develop --group kb-guests --upn guest@example.com
    python3 hygiene.py check      --product kb --env develop          # who would lose access
    python3 hygiene.py enforce    --product kb --env develop          # check again, then require assignment
    python3 hygiene.py rollback   --product kb --env develop
    python3 hygiene.py rotate     --product rova --env production --prod --cluster <c> --services api,worker --out-dir <d>
    python3 hygiene.py notes      [--force]
    python3 hygiene.py lock-app   --name "Claude for Outlook"
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import uuid
from dataclasses import dataclass
from typing import Callable

GRAPH = "https://graph.microsoft.com/v1.0"
AWS_PROFILE = "qnsc-admin"
AWS_REGION = "ap-southeast-1"
# The all-zero appRoleId means "default access" for apps that define no app roles.
DEFAULT_ROLE_ID = "00000000-0000-0000-0000-000000000000"
MEMBER_RULE = '(user.userType -eq "Member") and (user.accountEnabled -eq true)'
GROUP_DESCRIPTION = "Managed by infra/scripts/owner/entra-hygiene. Gates sign-in to a product app."
P1_PLANS = ("AAD_PREMIUM", "AAD_PREMIUM_P2")
SECRET_LIFETIME_DAYS = 180
ROTATE_BEFORE_EXPIRY_DAYS = 30
SIGNIN_WINDOW_DAYS = 30
ROLLOUT_WAIT_ATTEMPTS = 10
THROTTLED = ("TooManyRequests", "Too Many Requests", "(429)")
TRANSIENT = ("ServiceUnavailable", "(503)", "GatewayTimeout", "(504)")
NOT_FOUND = ("Request_ResourceNotFound", "Not Found(")


@dataclass(frozen=True)
class Group:
    name: str
    # Dynamic: every internal Member with an enabled account (needs Entra ID P1). Assigned: members added by hand.
    dynamic: bool


@dataclass(frozen=True)
class Product:
    sign_in_app: str  # display name of the sign-in app in Entra
    env: str  # "develop" or "production": as in the bundle name and the infra live stacks
    bundle: str  # Secrets Manager id of the product/env bundle
    bundle_field: str  # the bundle key the product's API reads its Entra client secret from
    groups: tuple[Group, ...]
    # App Role value every group is assigned to. None: default access (the app must define no app roles).
    role_value: str | None = None
    # False: the product admits its own users (rova: staff domain, invitation, held seat). Entra assignment is not used.
    assignment_admission: bool = True


PRODUCTS: dict[tuple[str, str], Product] = {
    ("rova", "develop"): Product("Rova Dev", "develop", "rova/develop/app", "entra-client-secret", (), assignment_admission=False),
    ("rova", "production"): Product("Rova Prod", "production", "rova/production/app", "entra-client-secret", (), assignment_admission=False),
    ("opshub", "develop"): Product(
        "OpsHub Dev",
        "develop",
        "opshub/develop/app",
        "entra-client-secret",
        # No guests group: OpsHub's sign-in refuses B2B guests (allowGuests: false).
        (Group("opshub-users", dynamic=True),),
        role_value="employee",
    ),
    ("kb", "develop"): Product(
        "KB Dev",
        "develop",
        "qnsc-kb/develop/app",
        "microsoft-client-secret",
        (Group("kb-users", dynamic=True), Group("kb-guests", dynamic=False)),
    ),
}

# Notes field values. Display names only: this file is in a public repository, so no tenant, app or object ids here.
REPO_BASE = "https://github.com/quynhonsemiconductor/"
NOTES: dict[str, str] = {
    "Rova Dev": REPO_BASE + "rova",
    "Rova Dev Service": REPO_BASE + "rova",
    "Rova Prod": REPO_BASE + "rova",
    "Rova Prod Service": REPO_BASE + "rova",
    "OpsHub Dev": REPO_BASE + "opshub",
    "OpsHub Dev Service": REPO_BASE + "opshub",
    "KB Dev": REPO_BASE + "qnsc-kb-backend",
    "KB Dev Service": REPO_BASE + "qnsc-kb-backend",
}


class GraphError(RuntimeError):
    pass


class AwsError(RuntimeError):
    pass


def require_assignment(product: Product) -> None:
    if not product.assignment_admission:
        raise GraphError(
            f"{product.sign_in_app} is admitted by rova itself (staff domain, invitation, held seat), not by app assignment: "
            "this command does not apply. rotate and notes still do. See README: why Rova is not on assignment."
        )


def has_p1(skus: list[dict]) -> bool:
    """A proxy for Entra ID P1: a P1 plan provisioned and assigned to at least one user."""
    for sku in skus:
        if (sku.get("consumedUnits") or 0) < 1:
            continue
        for plan in sku.get("servicePlans") or []:
            if plan.get("servicePlanName") in P1_PLANS and plan.get("provisioningStatus") == "Success":
                return True
    return False


def parse_time(text: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)


class GraphClient:
    """`az rest` wrapper. The only Entra access in this file."""

    def __init__(self, runner=subprocess.run, sleep=time.sleep):
        self.runner = runner
        self.sleep = sleep

    def call(self, method: str, url: str, body: dict | None = None, allow_missing: bool = False, headers: tuple[str, ...] = ()):
        args = ["az", "rest", "--method", method, "--url", url, "--output", "json"]
        if headers:
            args += ["--headers", *headers]
        if body is not None:
            args += ["--headers", "Content-Type=application/json", "--body", json.dumps(body)]
        # A POST that failed with 503/504 may still have been applied (a secret, a group). Only a 429 is retried for POST.
        retry_on = THROTTLED if method == "POST" else THROTTLED + TRANSIENT
        for attempt in range(4):
            proc = self.runner(args, capture_output=True, text=True)
            if proc.returncode == 0:
                return json.loads(proc.stdout) if proc.stdout.strip() else None
            if allow_missing and any(marker in proc.stderr for marker in NOT_FOUND):
                return None
            if attempt < 3 and any(marker in proc.stderr for marker in retry_on):
                self.sleep(10 * (attempt + 1))
                continue
            raise GraphError(f"{method} {url} failed:\n{proc.stderr.strip()}")
        raise GraphError(f"{method} {url} failed after retries")

    def all(self, url: str, headers: tuple[str, ...] = ()) -> list[dict]:
        items: list[dict] = []
        while url:
            page = self.call("GET", url, headers=headers)
            items.extend(page.get("value", []))
            url = page.get("@odata.nextLink")
        return items


class AwsClient:
    """AWS calls. Every command names the owner's admin profile and region."""

    def __init__(self, runner=subprocess.run):
        self.runner = runner

    def _json(self, args: list[str], stdin: str | None = None) -> dict:
        cmd = ["aws", *args, "--profile", AWS_PROFILE, "--region", AWS_REGION, "--output", "json"]
        proc = self.runner(cmd, input=stdin, capture_output=True, text=True)
        if proc.returncode != 0:
            raise AwsError(f"aws {' '.join(args[:2])} failed:\n{proc.stderr.strip()}")
        return json.loads(proc.stdout) if proc.stdout.strip() else {}

    def get_secret(self, secret_id: str) -> str:
        return self._json(["secretsmanager", "get-secret-value", "--secret-id", secret_id])["SecretString"]

    def put_secret(self, secret_id: str, text: str) -> None:
        # The value arrives on stdin, never in argv.
        self._json(["secretsmanager", "put-secret-value", "--secret-id", secret_id, "--secret-string", "file:///dev/stdin"], stdin=text)

    def list_services(self, cluster: str) -> list[str]:
        arns: list[str] = []
        token = None
        while True:
            args = ["ecs", "list-services", "--cluster", cluster, "--max-results", "100"]
            if token:
                args += ["--next-token", token]
            page = self._json(args)
            arns += page.get("serviceArns", [])
            token = page.get("nextToken")
            if not token:
                return arns

    def describe_services(self, cluster: str, names: list[str]) -> list[dict]:
        found: list[dict] = []
        for start in range(0, len(names), 10):
            page = self._json(["ecs", "describe-services", "--cluster", cluster, "--services", *names[start : start + 10]])
            found += page.get("services", [])
        return found

    def task_definition(self, arn: str) -> dict:
        return self._json(["ecs", "describe-task-definition", "--task-definition", arn])["taskDefinition"]

    def restart(self, cluster: str, service: str) -> None:
        self._json(["ecs", "update-service", "--cluster", cluster, "--service", service, "--force-new-deployment"])

    def wait_stable(self, cluster: str, service: str) -> None:
        self._json(["ecs", "wait", "services-stable", "--cluster", cluster, "--services", service])


def iso(when: dt.datetime) -> str:
    return when.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def odata_quote(value: str) -> str:
    return urllib.parse.quote(value.replace("'", "''"), safe="")


def references_bundle(task_def: dict, bundle: str) -> bool:
    """True when a container of the task definition names the bundle: as a `secrets` valueFrom or an env value."""
    pattern = re.compile(r"(^|:secret:)" + re.escape(bundle) + r"(-[A-Za-z0-9]{6})?(:|$)")
    for container in task_def.get("containerDefinitions", []):
        values = [s.get("valueFrom", "") for s in container.get("secrets", [])]
        values += [e.get("value", "") for e in container.get("environment", [])]
        if any(pattern.search(value) for value in values):
            return True
    return False


class Hygiene:
    def __init__(self, graph, aws, ask: Callable[[str], str] = input, out=print, now=None, sleep=time.sleep):
        self.graph = graph
        self.aws = aws
        self.ask = ask
        self.out = out
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.sleep = sleep

    # ── gates ─────────────────────────────────────────────────────────────────────────────────────────
    def confirm(self, question: str) -> bool:
        return self.ask(f"{question} [y/N] ").strip().lower() in ("y", "yes")

    def production_gate(self, product: Product) -> None:
        """Production writes need the app name typed, in addition to the y/N."""
        if product.env != "production":
            return
        typed = self.ask(f'PRODUCTION ({product.env}). Type the sign-in app name "{product.sign_in_app}" to continue: ')
        if typed.strip() != product.sign_in_app:
            raise GraphError("the typed name did not match; nothing changed")

    def preflight(self, need_p1: bool) -> None:
        """Read-only checks before any write: the sign-in log is readable, and P1 is present when groups need it."""
        try:
            self.graph.call("GET", f"{GRAPH}/auditLogs/signIns?$top=1")
        except GraphError as err:
            raise GraphError("cannot read the sign-in log (needs Reports Reader or Global Reader, AuditLog.Read.All): " + str(err)) from err
        if need_p1 and not has_p1(self.graph.all(f"{GRAPH}/subscribedSkus")):
            raise GraphError("no assigned Entra ID P1 (AAD_PREMIUM) license found: dynamic groups would not populate")

    # ── lookups (read-only) ───────────────────────────────────────────────────────────────────────────
    def find_app(self, name: str) -> dict | None:
        found = self.graph.all(f"{GRAPH}/applications?$filter=displayName%20eq%20'{odata_quote(name)}'&$top=10")
        if len(found) > 1:
            raise GraphError(f"more than one application named {name!r}; resolve the duplicate first")
        if not found:
            return None
        return self.graph.call(
            "GET",
            f"{GRAPH}/applications/{found[0]['id']}?$select=id,appId,displayName,notes,appRoles,passwordCredentials,servicePrincipalLockConfiguration",
        )

    def require_app(self, name: str) -> dict:
        app = self.find_app(name)
        if app is None:
            raise GraphError(f"no application named {name!r} in this tenant")
        return app

    def require_sp(self, app: dict) -> dict:
        sp = self.graph.call(
            "GET",
            f"{GRAPH}/servicePrincipals(appId='{app['appId']}')?$select=id,appId,displayName,appRoleAssignmentRequired",
            allow_missing=True,
        )
        if sp is None:
            raise GraphError(f"{app['displayName']!r} has no enterprise application (service principal) in this tenant")
        return sp

    def find_group(self, name: str) -> dict | None:
        select = "id,displayName,groupTypes,membershipRule,description,securityEnabled,mailEnabled"
        found = self.graph.all(f"{GRAPH}/groups?$filter=displayName%20eq%20'{odata_quote(name)}'&$select={select}")
        if len(found) > 1:
            raise GraphError(f"more than one group named {name!r}")
        return found[0] if found else None

    def group_members(self, group_id: str) -> set[str]:
        return {m["id"] for m in self.graph.all(f"{GRAPH}/groups/{group_id}/members?$select=id")}

    def assignments(self, sp_id: str) -> list[dict]:
        return self.graph.all(f"{GRAPH}/servicePrincipals/{sp_id}/appRoleAssignedTo")

    def successful_signins(self, app_id: str, since: dt.datetime, upn: str | None = None) -> list[dict]:
        url = (
            f"{GRAPH}/auditLogs/signIns?$filter=appId%20eq%20'{app_id}'%20and%20createdDateTime%20ge%20{iso(since)}"
        )
        if upn:
            url += f"%20and%20userPrincipalName%20eq%20'{odata_quote(upn)}'"
        url += "&$select=userId,userPrincipalName,status&$top=999"
        return [s for s in self.graph.all(url) if (s.get("status") or {}).get("errorCode") == 0]

    def operator_upn(self) -> str:
        return self.graph.call("GET", f"{GRAPH}/me?$select=userPrincipalName")["userPrincipalName"]

    def find_user(self, upn: str) -> dict:
        user = self.graph.call("GET", f"{GRAPH}/users/{odata_quote(upn)}?$select=id,userPrincipalName", allow_missing=True)
        if user is not None:
            return user
        # Guests carry the address in mail/otherMails; their UPN is <address>#EXT#@<tenant>.
        value = odata_quote(upn)
        query = f"mail%20eq%20'{value}'%20or%20otherMails/any(c:c%20eq%20'{value}')%20or%20userPrincipalName%20eq%20'{value}'"
        found = self.graph.all(
            f"{GRAPH}/users?$filter={query}&$count=true&$select=id,userPrincipalName",
            headers=("ConsistencyLevel=eventual",),
        )
        if len(found) != 1:
            raise GraphError(f"{len(found)} user(s) match {upn!r}; expected exactly one")
        return found[0]

    # ── read-only status ──────────────────────────────────────────────────────────────────────────────
    def status(self, product: Product) -> None:
        app = self.require_app(product.sign_in_app)
        sp = self.require_sp(app)
        self.out(f"{app['displayName']} ({product.env}): appRoleAssignmentRequired={sp['appRoleAssignmentRequired']}")
        self.out(f"  notes set: {bool(app.get('notes'))}; app roles defined: {len(app.get('appRoles') or [])}")
        self.out(f"  instance lock: {(app.get('servicePrincipalLockConfiguration') or {}).get('isEnabled')}")
        self.out(f"  bundle {product.bundle} key {product.bundle_field} (value never read here)")
        for credential_meta in app.get("passwordCredentials") or []:
            self.out(f"  credential keyId={credential_meta['keyId']} name={credential_meta.get('displayName')} ends={credential_meta.get('endDateTime')}")
        for group in product.groups:
            found = self.find_group(group.name)
            self.out(f"  group {group.name}: {'missing' if found is None else 'exists'}")
        for assignment in self.assignments(sp["id"]):
            self.out(f"  assigned: {assignment.get('principalType')} {assignment.get('principalDisplayName')} role {assignment.get('appRoleId')}")

    # ── app role (OpsHub) ─────────────────────────────────────────────────────────────────────────────
    def add_role(self, product: Product) -> None:
        require_assignment(product)
        if product.role_value is None:
            raise GraphError(f"{product.sign_in_app} uses default access; no app role to add")
        app = self.require_app(product.sign_in_app)
        existing = app.get("appRoles") or []
        present = [r for r in existing if r.get("value") == product.role_value]
        if present:
            if not any(r.get("isEnabled") for r in present):
                raise GraphError(
                    f"{product.sign_in_app}: app role {product.role_value!r} exists but is disabled; "
                    "enable it by hand in the portal, then re-run"
                )
            self.out(f"{product.sign_in_app}: app role {product.role_value!r} already present and enabled")
            return
        self.production_gate(product)
        if not self.confirm(f"Add app role {product.role_value!r} to {product.sign_in_app} ({product.env})?"):
            return
        kept = [
            {k: r[k] for k in ("id", "allowedMemberTypes", "description", "displayName", "isEnabled", "value") if k in r}
            for r in existing
        ]
        new = {
            "id": str(uuid.uuid4()),
            "allowedMemberTypes": ["User"],
            "description": "Ordinary staff of OpsHub. Holds no elevated role; same access as having no role.",
            "displayName": "Employee",
            "isEnabled": True,
            "value": product.role_value,
        }
        self.graph.call("PATCH", f"{GRAPH}/applications/{app['id']}", {"appRoles": kept + [new]})
        after = self.require_app(product.sign_in_app).get("appRoles") or []
        if not any(r.get("value") == product.role_value and r.get("isEnabled") for r in after):
            raise GraphError("app role write returned, but a read does not show it enabled")
        self.out(f"{product.sign_in_app}: app role {product.role_value!r} added and read back")

    def role_id(self, app: dict, product: Product) -> str:
        roles = app.get("appRoles") or []
        if product.role_value is None:
            if roles:
                raise GraphError(f"{app['displayName']} defines app roles; this product must use default access (no roles)")
            return DEFAULT_ROLE_ID
        match = [r for r in roles if r.get("value") == product.role_value and r.get("isEnabled")]
        if not match:
            raise GraphError(
                f"{app['displayName']} has no enabled app role {product.role_value!r}; run add-role first, "
                "or enable it by hand if it exists disabled"
            )
        return match[0]["id"]

    # ── setup: groups and assignments ─────────────────────────────────────────────────────────────────
    def verify_group(self, found: dict, group: Group) -> None:
        want_types = ["DynamicMembership"] if group.dynamic else []
        ok = (
            (found.get("groupTypes") or []) == want_types
            and found.get("securityEnabled") is True
            and found.get("mailEnabled") is False
            and found.get("description") == GROUP_DESCRIPTION
            and (not group.dynamic or found.get("membershipRule") == MEMBER_RULE)
        )
        if not ok:
            raise GraphError(
                f"group {group.name!r} exists with other type, rule, description or security flags; "
                "fix or rename it by hand before setup reuses it"
            )

    def ensure_group(self, group: Group) -> str:
        existing = self.find_group(group.name)
        if existing:
            self.verify_group(existing, group)
            return existing["id"]
        body = {
            "displayName": group.name,
            "mailNickname": group.name,
            "mailEnabled": False,
            "securityEnabled": True,
            "description": GROUP_DESCRIPTION,
            "groupTypes": ["DynamicMembership"] if group.dynamic else [],
        }
        if group.dynamic:
            body["membershipRule"] = MEMBER_RULE
            body["membershipRuleProcessingState"] = "On"
        return self.graph.call("POST", f"{GRAPH}/groups", body)["id"]

    def setup(self, product: Product) -> None:
        require_assignment(product)
        app = self.require_app(product.sign_in_app)
        sp = self.require_sp(app)
        role_id = self.role_id(app, product)
        self.preflight(need_p1=any(g.dynamic for g in product.groups))
        self.out(f"Plan for {app['displayName']} ({product.env}):")
        for group in product.groups:
            self.out(f"  ensure group {group.name} ({'dynamic: every enabled internal Member' if group.dynamic else 'assigned'})")
            self.out(f"  assign it to {app['displayName']} with role {product.role_value or 'default access'}")
        self.production_gate(product)
        if not self.confirm("Create the missing groups and assign them?"):
            return
        assigned = {(a.get("principalId"), a.get("appRoleId")) for a in self.assignments(sp["id"])}
        for group in product.groups:
            group_id = self.ensure_group(group)
            if (group_id, role_id) in assigned:
                self.out(f"  {group.name}: already assigned")
                continue
            self.graph.call(
                "POST",
                f"{GRAPH}/servicePrincipals/{sp['id']}/appRoleAssignedTo",
                {"principalId": group_id, "resourceId": sp["id"], "appRoleId": role_id},
            )
            self.out(f"  {group.name}: assigned")

    def add_member(self, product: Product, group_name: str, upn: str) -> None:
        require_assignment(product)
        if group_name not in {g.name for g in product.groups if not g.dynamic}:
            raise GraphError(f"{group_name!r} is not an assigned group of this product (dynamic groups fill themselves)")
        group = self.find_group(group_name)
        if group is None:
            raise GraphError(f"group {group_name!r} does not exist; run setup first")
        user = self.find_user(upn)
        if user["id"] in self.group_members(group["id"]):
            self.out(f"{user['userPrincipalName']} is already in {group_name}")
            return
        self.production_gate(product)
        if not self.confirm(f"Add {user['userPrincipalName']} to {group_name} ({product.env})?"):
            return
        self.graph.call("POST", f"{GRAPH}/groups/{group['id']}/members/$ref", {"@odata.id": f"{GRAPH}/directoryObjects/{user['id']}"})
        self.out(f"added {user['userPrincipalName']} to {group_name}")

    # ── assignment required: check, enforce, roll back ────────────────────────────────────────────────
    def lost_access(self, product: Product) -> list[str]:
        """UPNs that signed in to the app in the window and would be refused once assignment is required.

        The allowed set is built ONLY from the app's own assignments: users assigned directly, and members of the
        product's groups that are assigned to the app. A group that exists but is not assigned allows nobody.
        """
        require_assignment(product)
        self.preflight(need_p1=False)
        app = self.require_app(product.sign_in_app)
        sp = self.require_sp(app)
        role = self.role_id(app, product)
        assignments = self.assignments(sp["id"])
        allowed: set[str] = {a["principalId"] for a in assignments if a.get("principalType") == "User"}
        for group in product.groups:
            found = self.find_group(group.name)
            if found is None:
                raise GraphError(f"group {group.name!r} is missing; run setup first")
            if not any(a.get("principalId") == found["id"] and a.get("appRoleId") == role for a in assignments):
                raise GraphError(f"group {group.name!r} is not assigned to {product.sign_in_app}; half-applied setup, run setup first")
            allowed |= self.group_members(found["id"])
        since = self.now() - dt.timedelta(days=SIGNIN_WINDOW_DAYS)
        seen = {s["userId"]: s.get("userPrincipalName") or s["userId"] for s in self.successful_signins(app["appId"], since)}
        self.out(f"{app['displayName']}: {len(seen)} user(s) signed in since {since:%Y-%m-%d}; {len(allowed)} allowed by assignment")
        lost = sorted(upn for uid, upn in seen.items() if uid not in allowed)
        for upn in lost:
            self.out(f"  WOULD LOSE ACCESS: {upn}")
        return lost

    def enforce(self, product: Product, flag: bool) -> None:
        require_assignment(product)
        app = self.require_app(product.sign_in_app)
        sp = self.require_sp(app)
        if flag:
            lost = self.lost_access(product)
            if lost:
                raise GraphError(f"{len(lost)} user(s) would lose access; add them (add-member) or confirm they must go, then check again")
        self.production_gate(product)
        verb = "require" if flag else "stop requiring"
        if not self.confirm(f"{verb.capitalize()} app assignment on {app['displayName']} ({product.env})?"):
            return
        self.graph.call("PATCH", f"{GRAPH}/servicePrincipals/{sp['id']}", {"appRoleAssignmentRequired": flag})
        self.out(f"{app['displayName']} ({product.env}): appRoleAssignmentRequired={flag}")

    # ── secret rotation ───────────────────────────────────────────────────────────────────────────────
    def rotate(self, product: Product, cluster: str, services: list[str], out_dir: str) -> int:
        if not services:
            raise GraphError("--services is empty: name every ECS service that reads the bundle")
        self.preflight(need_p1=False)
        upn = self.operator_upn()
        app = self.require_app(product.sign_in_app)
        bundle = self.read_bundle(product)
        previous = bundle.get(product.bundle_field)
        if not isinstance(previous, str) or not previous:
            raise GraphError(f"bundle {product.bundle} key {product.bundle_field} is missing or not a string: nothing changed")
        hint = previous[:3]  # matching only: never printed
        matches = [c for c in app.get("passwordCredentials") or [] if c.get("hint") == hint]
        if len(matches) != 1:
            listing = ", ".join(f"keyId={c['keyId']} name={c.get('displayName')} ends={c.get('endDateTime')}" for c in app.get("passwordCredentials") or [])
            raise GraphError(f"{len(matches)} Entra credential(s) match the bundle's current value: {listing}. Nothing changed.")
        old_meta = matches[0]
        old_id = old_meta["keyId"]
        unknown = sorted(set(services) - set(self.cluster_services(cluster)))
        if unknown:
            raise GraphError(f"not services of cluster {cluster}: {', '.join(unknown)}. Nothing changed.")
        consumers = self.consumers(cluster, product.bundle)
        if not consumers:
            raise GraphError(f"no service in cluster {cluster} reads bundle {product.bundle}: check --cluster")
        missing = sorted(consumers - set(services))
        if missing:
            raise GraphError(f"services that read the bundle but are not in --services: {', '.join(missing)}. Nothing changed.")
        self.out(f"{app['displayName']} ({product.env}): old credential keyId {old_id} (name {old_meta.get('displayName')}, ends {old_meta.get('endDateTime')}), kept until verified")
        self.out(f"  bundle {product.bundle} key {product.bundle_field}; consumers in {cluster}: {', '.join(sorted(consumers))}")
        for other in app.get("passwordCredentials") or []:
            if other["keyId"] != old_id:
                self.out(f"  other credential keyId={other['keyId']} name={other.get('displayName')}: not touched")
        self.production_gate(product)
        if not self.confirm(f"Add a new client secret (180 days) and write it to the bundle ({product.env})?"):
            return 1
        expiry = self.now() + dt.timedelta(days=SECRET_LIFETIME_DAYS)
        new = self.graph.call(
            "POST",
            f"{GRAPH}/applications/{app['id']}/addPassword",
            {"passwordCredential": {"displayName": f"rotated {self.now():%Y-%m-%d}", "endDateTime": iso(expiry)}},
        )
        secret = new.pop("secretText")
        new_id, ends = new["keyId"], new["endDateTime"]
        if new.get("hint") and new["hint"] != secret[:3]:
            self.remove_secret(app, new_id)
            raise GraphError("the new secret's hint does not match its value: removed it; nothing else changed")
        self.out(f"  new secret keyId {new_id}, ends {ends}, length {len(secret)} (value not shown)")
        self.write_bundle(product, app, previous, secret, new_id)
        del secret
        written_at = self.now()
        self.out(f"  bundle written and read back: key {product.bundle_field} changed, other keys unchanged")

        if not self.confirm(f"Restart {', '.join(services)} in {cluster} now (rolling)?"):
            self.out("Stopped before restart. Both secrets are valid; nothing removed. Restart later, then verify.")
            return 1
        for service in services:
            self.aws.restart(cluster, service)
        for service in services:
            self.aws.wait_stable(cluster, service)
        restarted = self.now()
        if not self.rollout_ok(cluster, services, written_at):
            return self.rollback_rotation(product, app, cluster, services, previous, new_id)
        self.out("  every consumer has one PRIMARY deployment created after the bundle write, running == desired")

        prompt = f"Reached {app['displayName']} ({product.env}) signed in as {upn}, in a private window?"
        if not self.confirm(prompt):
            return self.rollback_rotation(product, app, cluster, services, previous, new_id)
        if not self.signed_in_after(app["appId"], upn, restarted):
            self.out("  you reported a sign-in, but the sign-in log has no successful sign-in by you after the restart yet.")
            self.out(f"  Both secrets are valid; nothing removed; the new secret (keyId {new_id}) is in the bundle.")
            self.out("  Wait a few minutes, check the sign-in log, then finish with:")
            self.out(f"    python3 scripts/owner/entra-hygiene/hygiene.py remove-secret --product {product_key(product)} "
                     f"--env {product.env} --key-id {old_id}")
            return 1

        if self.confirm(f"Remove the old credential keyId {old_id} (ends {old_meta.get('endDateTime')}) now?"):
            self.remove_secret(app, old_id)
        due = parse_time(ends) - dt.timedelta(days=ROTATE_BEFORE_EXPIRY_DAYS)
        path = write_calendar(out_dir, app["displayName"], due, ends)
        self.out(f"Next rotation due {due:%Y-%m-%d} (30 days before {ends}). Calendar file: {path}")
        return 0

    def read_bundle(self, product: Product) -> dict:
        try:
            bundle = json.loads(self.aws.get_secret(product.bundle))
        except json.JSONDecodeError as err:
            raise GraphError(f"bundle {product.bundle} is not JSON: nothing changed") from err
        if not isinstance(bundle, dict):
            raise GraphError(f"bundle {product.bundle} is not a JSON object: nothing changed")
        return bundle

    def write_bundle(self, product: Product, app: dict, previous: str, secret: str, new_id: str) -> None:
        before = self.read_bundle(product)
        updated = dict(before)
        updated[product.bundle_field] = secret
        try:
            self.aws.put_secret(product.bundle, json.dumps(updated))
            after = json.loads(self.aws.get_secret(product.bundle))
            same_keys = set(after) == set(before)
            only_key_changed = all(after[k] == before[k] for k in before if k != product.bundle_field)
            if not (same_keys and only_key_changed and after[product.bundle_field] == secret):
                raise AwsError("read-back differs from what was written")
        except Exception:
            self.undo_failed_write(product, app, previous, new_id)
            raise

    def undo_failed_write(self, product: Product, app: dict, previous: str, new_id: str) -> None:
        """Put the previous value back if the bundle does not hold it, then remove the new secret. Keep the new
        secret if neither is certain: a valid, unused secret is safer than an unknown bundle with nothing to fall back to."""
        try:
            current = self.read_bundle(product)
            if current.get(product.bundle_field) != previous:
                current[product.bundle_field] = previous
                self.aws.put_secret(product.bundle, json.dumps(current))
                if self.read_bundle(product).get(product.bundle_field) != previous:
                    raise AwsError("restore of the previous value did not read back")
            self.remove_secret(app, new_id)
            self.out("  bundle failed to write: previous value confirmed, new secret removed")
        except Exception as err:
            self.out(f"  bundle state unknown after a failed write ({type(err).__name__}); new keyId {new_id} KEPT. Check the bundle by hand.")

    def cluster_services(self, cluster: str) -> list[str]:
        return [arn.rsplit("/", 1)[-1] for arn in self.aws.list_services(cluster)]

    def consumers(self, cluster: str, bundle: str) -> set[str]:
        found: set[str] = set()
        for svc in self.aws.describe_services(cluster, self.cluster_services(cluster)):
            if references_bundle(self.aws.task_definition(svc["taskDefinition"]), bundle):
                found.add(svc["serviceName"])
        return found

    def rollout_ok(self, cluster: str, services: list[str], written_at: dt.datetime) -> bool:
        ok = True
        for svc in self.aws.describe_services(cluster, services):
            primary = [d for d in svc.get("deployments", []) if d.get("status") == "PRIMARY"]
            if len(primary) != 1:
                self.out(f"  {svc['serviceName']}: {len(primary)} PRIMARY deployments (want 1)")
                ok = False
                continue
            d = primary[0]
            if parse_time(d["createdAt"]) <= written_at:
                self.out(f"  {svc['serviceName']}: PRIMARY deployment predates the bundle write")
                ok = False
            if not (d.get("runningCount") == d.get("desiredCount") and d.get("rolloutState") == "COMPLETED"):
                self.out(f"  {svc['serviceName']}: running {d.get('runningCount')} of {d.get('desiredCount')}, rollout {d.get('rolloutState')}")
                ok = False
        return ok

    def rollback_rotation(self, product: Product, app: dict, cluster: str, services: list[str], previous: str, new_id: str) -> int:
        current = self.read_bundle(product)
        current[product.bundle_field] = previous
        self.aws.put_secret(product.bundle, json.dumps(current))
        if self.read_bundle(product).get(product.bundle_field) != previous:
            raise AwsError("rollback: restore of the previous value did not read back; new secret kept, check by hand")
        del current
        for service in services:
            self.aws.restart(cluster, service)
        for service in services:
            self.aws.wait_stable(cluster, service)
        self.remove_secret(app, new_id)
        self.out(f"Rolled back: previous value restored, services restarted, new keyId {new_id} removed.")
        return 1

    def remove_old_secret(self, product: Product, key_id: str) -> None:
        """Finish a rotation: remove one named secret, refusing the one the bundle holds now."""
        app = self.require_app(product.sign_in_app)
        bundle = self.read_bundle(product)
        current = bundle.get(product.bundle_field)
        if not isinstance(current, str) or not current:
            raise GraphError(f"bundle {product.bundle} key {product.bundle_field} is missing: nothing changed")
        credential_meta = next((c for c in app.get("passwordCredentials") or [] if c["keyId"] == key_id), None)
        if credential_meta is None:
            raise GraphError(f"keyId {key_id} is not a secret of {product.sign_in_app}")
        if credential_meta.get("hint") == current[:3]:  # matching only
            raise GraphError(f"keyId {key_id} matches the secret the bundle holds now; refusing to remove it")
        if not self.confirm(f"Remove credential keyId {key_id} (ends {credential_meta.get('endDateTime')}) from {product.sign_in_app} ({product.env})?"):
            return
        self.remove_secret(app, key_id)
        self.out(f"removed keyId {key_id}")

    def remove_secret(self, app: dict, key_id: str) -> None:
        self.graph.call("POST", f"{GRAPH}/applications/{app['id']}/removePassword", {"keyId": key_id})

    def signed_in_after(self, app_id: str, upn: str, since: dt.datetime) -> bool:
        for attempt in range(ROLLOUT_WAIT_ATTEMPTS):
            if self.successful_signins(app_id, since, upn=upn):
                return True
            if attempt < ROLLOUT_WAIT_ATTEMPTS - 1:
                self.sleep(30)
        return False

    # ── notes and lock ────────────────────────────────────────────────────────────────────────────────
    def notes(self, force: bool) -> None:
        for name, link in NOTES.items():
            app = self.find_app(name)
            if app is None:
                self.out(f"  {name}: not in this tenant, skipped")
                continue
            if app.get("notes") and not force:
                self.out(f"  {name}: Notes already set, kept (use --force to replace)")
                continue
            if not self.confirm(f"Set Notes on {name} to {link}?"):
                continue
            self.graph.call("PATCH", f"{GRAPH}/applications/{app['id']}", {"notes": link})
            self.out(f"  {name}: Notes set")

    def lock_app(self, name: str) -> None:
        app = self.require_app(name)
        lock = app.get("servicePrincipalLockConfiguration") or {}
        if lock.get("isEnabled") and lock.get("allProperties"):
            self.out(f"{name}: instance property lock already on")
            return
        if not self.confirm(f"Turn on the application instance property lock (all properties) for {name}?"):
            return
        self.graph.call("PATCH", f"{GRAPH}/applications/{app['id']}", {"servicePrincipalLockConfiguration": {"isEnabled": True, "allProperties": True}})
        after = self.require_app(name).get("servicePrincipalLockConfiguration") or {}
        if not (after.get("isEnabled") and after.get("allProperties")):
            raise GraphError(f"{name}: lock write returned, but a read shows {after}")
        self.out(f"{name}: instance property lock on (read back)")


def product_key(product: Product) -> str:
    return next(name for (name, _env), value in PRODUCTS.items() if value is product)


def write_calendar(out_dir: str, app_name: str, due: dt.datetime, expiry: str) -> str:
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    day = due.strftime("%Y%m%d")
    next_day = (due + dt.timedelta(days=1)).strftime("%Y%m%d")
    safe = "".join(c if c.isalnum() else "-" for c in app_name.lower())
    path = os.path.join(out_dir, f"rotate-{safe}.ics")
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//QNSC//entra-hygiene//EN",
        "BEGIN:VEVENT",
        f"UID:{uuid.uuid4()}@qnsc-entra-hygiene",
        f"DTSTAMP:{dt.datetime.now(dt.timezone.utc):%Y%m%dT%H%M%SZ}",
        f"DTSTART;VALUE=DATE:{day}",
        f"DTEND;VALUE=DATE:{next_day}",
        f"SUMMARY:Rotate {app_name} client secret",
        f"DESCRIPTION:Secret expires {expiry}. Run hygiene.py rotate for this product and env.",
        "END:VEVENT",
        "END:VCALENDAR",
    ]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\r\n".join(lines) + "\r\n")
    return path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def product_args(p):
        p.add_argument("--product", required=True, choices=sorted({k[0] for k in PRODUCTS}))
        p.add_argument("--env", required=True, choices=["develop", "production"])
        p.add_argument("--prod", action="store_true", help="required with --env production")

    product_args(sub.add_parser("status", help="read-only: state of the sign-in app"))
    product_args(sub.add_parser("setup", help="create groups and assign them to the app"))
    product_args(sub.add_parser("add-role", help="add the App Role the product's groups are assigned to"))
    p = sub.add_parser("add-member", help="add a guest or user to an assigned group")
    product_args(p)
    p.add_argument("--group", required=True)
    p.add_argument("--upn", required=True)
    product_args(sub.add_parser("check", help="read-only: who would lose access"))
    product_args(sub.add_parser("enforce", help="require assignment (runs check first)"))
    product_args(sub.add_parser("rollback", help="stop requiring assignment"))
    p = sub.add_parser("rotate", help="rotate the sign-in app client secret")
    product_args(p)
    p.add_argument("--cluster", required=True)
    p.add_argument("--services", required=True, help="comma-separated ECS services; must include every service that reads the bundle")
    p.add_argument("--out-dir", required=True, help="directory OUTSIDE any git repository for the calendar file")
    p = sub.add_parser("remove-secret", help="finish a rotation: remove the named old secret")
    product_args(p)
    p.add_argument("--key-id", required=True)
    p = sub.add_parser("notes", help="set Notes (repo link) on the known apps")
    p.add_argument("--force", action="store_true", help="replace Notes that are already set")
    p = sub.add_parser("lock-app", help="application instance property lock on one app")
    p.add_argument("--name", required=True)
    return parser


def main(argv: list[str] | None = None, graph=None, aws=None, hygiene: Hygiene | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    h = hygiene or Hygiene(graph or GraphClient(), aws or AwsClient())
    if args.command == "notes":
        h.notes(args.force)
        return 0
    if args.command == "lock-app":
        h.lock_app(args.name)
        return 0
    product = PRODUCTS.get((args.product, args.env))
    if product is None:
        parser.error(f"no {args.product} {args.env} product configured")
    if product.env == "production" and not args.prod:
        parser.error("--env production also needs --prod")
    if args.command == "status":
        h.status(product)
    elif args.command == "setup":
        h.setup(product)
    elif args.command == "add-role":
        h.add_role(product)
    elif args.command == "add-member":
        h.add_member(product, args.group, args.upn)
    elif args.command == "check":
        h.lost_access(product)
    elif args.command == "enforce":
        h.enforce(product, True)
    elif args.command == "rollback":
        h.enforce(product, False)
    elif args.command == "remove-secret":
        h.remove_old_secret(product, args.key_id)
    elif args.command == "rotate":
        return h.rotate(product, args.cluster, [s for s in args.services.split(",") if s], args.out_dir)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (GraphError, AwsError) as err:
        sys.exit(f"hygiene: {err}")
