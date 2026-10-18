#!/usr/bin/env python3
"""Owner runbook helper for the Entra sign-in app hygiene track (see README.md next to this file).

Every Entra call goes through `az rest` (the signed-in Entra admin of the owner's terminal). Every AWS call names
`--profile qnsc-admin`. Secret values travel only in memory and on stdin: they are never printed, never put on a
command line, and never written to disk. Mutating commands print the plan and ask for `y` before any write.

    python3 hygiene.py status  --product rova --env dev
    python3 hygiene.py setup   --product rova --env dev          # create groups, assign them to the app
    python3 hygiene.py add-member --product rova --env dev --group vendors-rova --upn a@example.com
    python3 hygiene.py check   --product rova --env dev          # who would lose access if assignment is required
    python3 hygiene.py enforce --product rova --env dev          # check again, then appRoleAssignmentRequired = true
    python3 hygiene.py rollback --product rova --env dev         # appRoleAssignmentRequired = false
    python3 hygiene.py rotate  --product rova --env dev --cluster <ecs-cluster> --services api,worker --out-dir <dir>
    python3 hygiene.py notes   [--force]                         # Notes field (repo link) on the known apps
    python3 hygiene.py lock-app --name "Claude for Outlook"      # application instance property lock
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
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
REPO_BASE = "https://github.com/quynhonsemiconductor/"
# The all-zero appRoleId means "default access" for apps that define no app roles.
DEFAULT_ROLE_ID = "00000000-0000-0000-0000-000000000000"
MEMBER_RULE = '(user.userType -eq "Member")'
SECRET_LIFETIME_DAYS = 180
ROTATE_BEFORE_EXPIRY_DAYS = 30
SIGNIN_WINDOW_DAYS = 30
CLIENT_SECRET_KEY = "entra-client-secret"
THROTTLE_MARKERS = ("TooManyRequests", "Too Many Requests", "(429)", "ServiceUnavailable", "(503)", "(504)")
NOT_FOUND_MARKERS = ("Request_ResourceNotFound", "Not Found(")


@dataclass(frozen=True)
class Group:
    name: str
    # Dynamic: every licensed internal Member joins (needs Entra ID P1). Assigned: members added by hand or by rova.
    dynamic: bool


@dataclass(frozen=True)
class Product:
    sign_in_app: str  # display name of the sign-in app in Entra
    bundle: str  # Secrets Manager id of the product/env bundle
    groups: tuple[Group, ...]


USERS_DYNAMIC = Group("rova-users", dynamic=True)
PRODUCTS: dict[tuple[str, str], Product] = {
    ("rova", "dev"): Product("Rova Dev", "rova/dev/app", (USERS_DYNAMIC, Group("vendors-rova", dynamic=False))),
    ("rova", "prod"): Product("Rova Prod", "rova/prod/app", (USERS_DYNAMIC, Group("vendors-rova", dynamic=False))),
    ("opshub", "dev"): Product("OpsHub Dev", "opshub/dev/app", (Group("opshub-users", dynamic=True),)),
    ("kb", "dev"): Product("KB Dev", "qnsc-kb/dev/app", (Group("kb-users", dynamic=True),)),
}

# Notes field values. Display names only: this file is in a public repository, so no tenant, app or object ids here.
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


class GraphClient:
    """Thin `az rest` wrapper. The only Entra access in this file."""

    def __init__(self, runner=subprocess.run, sleep=time.sleep):
        self.runner = runner
        self.sleep = sleep

    def call(self, method: str, url: str, body: dict | None = None, allow_missing: bool = False):
        args = ["az", "rest", "--method", method, "--url", url, "--output", "json"]
        if body is not None:
            args += ["--headers", "Content-Type=application/json", "--body", json.dumps(body)]
        for attempt in range(4):
            proc = self.runner(args, capture_output=True, text=True)
            if proc.returncode == 0:
                return json.loads(proc.stdout) if proc.stdout.strip() else None
            if allow_missing and any(marker in proc.stderr for marker in NOT_FOUND_MARKERS):
                return None
            if attempt < 3 and any(marker in proc.stderr for marker in THROTTLE_MARKERS):
                self.sleep(10 * (attempt + 1))
                continue
            raise GraphError(f"{method} {url} failed:\n{proc.stderr.strip()}")
        raise GraphError(f"{method} {url} failed after retries")

    def all(self, url: str) -> list[dict]:
        items: list[dict] = []
        while url:
            page = self.call("GET", url)
            items.extend(page.get("value", []))
            url = page.get("@odata.nextLink")
        return items


class AwsClient:
    """AWS calls. Every command names the owner's admin profile and region."""

    def __init__(self, runner=subprocess.run):
        self.runner = runner

    def _run(self, args: list[str], stdin: str | None = None) -> str:
        cmd = ["aws", *args, "--profile", AWS_PROFILE, "--region", AWS_REGION]
        proc = self.runner(cmd, input=stdin, capture_output=True, text=True)
        if proc.returncode != 0:
            raise AwsError(f"aws {' '.join(args[:2])} failed:\n{proc.stderr.strip()}")
        return proc.stdout

    def get_secret(self, secret_id: str) -> str:
        return self._run(
            ["secretsmanager", "get-secret-value", "--secret-id", secret_id, "--query", "SecretString", "--output", "text"]
        )

    def put_secret(self, secret_id: str, text: str) -> None:
        # The value arrives on stdin, never in argv.
        self._run(["secretsmanager", "put-secret-value", "--secret-id", secret_id, "--secret-string", "file:///dev/stdin"], stdin=text)

    def restart(self, cluster: str, service: str) -> None:
        self._run(["ecs", "update-service", "--cluster", cluster, "--service", service, "--force-new-deployment", "--output", "json"])

    def wait_stable(self, cluster: str, service: str) -> None:
        self._run(["ecs", "wait", "services-stable", "--cluster", cluster, "--services", service])


def iso(when: dt.datetime) -> str:
    return when.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def odata_quote(value: str) -> str:
    return urllib.parse.quote(value.replace("'", "''"), safe="")


class Hygiene:
    def __init__(self, graph, aws, ask: Callable[[str], str] = input, out=print, now=None, sleep=time.sleep):
        self.graph = graph
        self.aws = aws
        self.ask = ask
        self.out = out
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.sleep = sleep

    # ── lookups (read-only) ───────────────────────────────────────────────────────────────────────────
    def find_app(self, name: str) -> dict | None:
        found = self.graph.all(f"{GRAPH}/applications?$filter=displayName%20eq%20'{odata_quote(name)}'&$top=10")
        if len(found) > 1:
            raise GraphError(f"more than one application named {name!r}; resolve the duplicate first")
        if not found:
            return None
        return self.graph.call("GET", f"{GRAPH}/applications/{found[0]['id']}?$select=id,appId,displayName,notes,appRoles,passwordCredentials,servicePrincipalLockConfiguration")

    def require_app(self, name: str) -> dict:
        app = self.find_app(name)
        if app is None:
            raise GraphError(f"no application named {name!r} in this tenant")
        return app

    def find_sp(self, app_id: str) -> dict | None:
        return self.graph.call("GET", f"{GRAPH}/servicePrincipals(appId='{app_id}')?$select=id,appId,displayName,appRoleAssignmentRequired", allow_missing=True)

    def require_sp(self, app: dict) -> dict:
        sp = self.find_sp(app["appId"])
        if sp is None:
            raise GraphError(f"{app['displayName']!r} has no enterprise application (service principal) in this tenant")
        return sp

    def find_group(self, name: str) -> dict | None:
        found = self.graph.all(f"{GRAPH}/groups?$filter=displayName%20eq%20'{odata_quote(name)}'&$select=id,displayName,groupTypes")
        if len(found) > 1:
            raise GraphError(f"more than one group named {name!r}")
        return found[0] if found else None

    def group_members(self, group_id: str) -> set[str]:
        return {m["id"] for m in self.graph.all(f"{GRAPH}/groups/{group_id}/members?$select=id")}

    def assignments(self, sp_id: str) -> list[dict]:
        return self.graph.all(f"{GRAPH}/servicePrincipals/{sp_id}/appRoleAssignedTo")

    def successful_signins(self, app_id: str, since: dt.datetime) -> list[dict]:
        url = (
            f"{GRAPH}/auditLogs/signIns?$filter=appId%20eq%20'{app_id}'%20and%20createdDateTime%20ge%20{iso(since)}"
            "&$select=userId,userPrincipalName,status&$top=999"
        )
        return [s for s in self.graph.all(url) if (s.get("status") or {}).get("errorCode") == 0]

    def confirm(self, question: str) -> bool:
        return self.ask(f"{question} [y/N] ").strip().lower() in ("y", "yes")

    # ── read-only status ──────────────────────────────────────────────────────────────────────────────
    def status(self, product: Product) -> None:
        app = self.require_app(product.sign_in_app)
        sp = self.require_sp(app)
        self.out(f"{app['displayName']}: appRoleAssignmentRequired={sp['appRoleAssignmentRequired']}")
        self.out(f"  notes set: {bool(app.get('notes'))}; app roles defined: {len(app.get('appRoles') or [])}")
        self.out(f"  instance lock: {(app.get('servicePrincipalLockConfiguration') or {}).get('isEnabled')}")
        for cred in app.get("passwordCredentials") or []:
            self.out(f"  secret keyId={cred['keyId']} ends={cred.get('endDateTime')} (value never read)")
        for group in product.groups:
            found = self.find_group(group.name)
            self.out(f"  group {group.name}: {'missing' if found is None else 'exists'}")
        for assignment in self.assignments(sp["id"]):
            self.out(f"  assigned: {assignment.get('principalType')} {assignment.get('principalDisplayName')}")

    # ── setup: groups and assignments ─────────────────────────────────────────────────────────────────
    def ensure_group(self, group: Group) -> str:
        existing = self.find_group(group.name)
        if existing:
            return existing["id"]
        body = {
            "displayName": group.name,
            "mailNickname": group.name,
            "mailEnabled": False,
            "securityEnabled": True,
            "description": "Managed by infra/scripts/owner/entra-hygiene. Gates sign-in to a product app.",
            "groupTypes": ["DynamicMembership"] if group.dynamic else [],
        }
        if group.dynamic:
            body["membershipRule"] = MEMBER_RULE
            body["membershipRuleProcessingState"] = "On"
        return self.graph.call("POST", f"{GRAPH}/groups", body)["id"]

    def setup(self, product: Product) -> None:
        app = self.require_app(product.sign_in_app)
        sp = self.require_sp(app)
        if app.get("appRoles"):
            names = ", ".join(role.get("value") or role.get("displayName", "?") for role in app["appRoles"])
            raise GraphError(f"{app['displayName']} defines app roles ({names}); this helper assigns default access only")
        self.out(f"Plan for {app['displayName']}:")
        for group in product.groups:
            self.out(f"  ensure group {group.name} ({'dynamic: all Members' if group.dynamic else 'assigned'})")
        self.out(f"  assign each group to {app['displayName']} with default access")
        if not self.confirm("Create the missing groups and assign them?"):
            return
        assigned = {(a.get("principalId"), a.get("appRoleId")) for a in self.assignments(sp["id"])}
        for group in product.groups:
            group_id = self.ensure_group(group)
            if (group_id, DEFAULT_ROLE_ID) in assigned:
                self.out(f"  {group.name}: already assigned")
                continue
            self.graph.call(
                "POST",
                f"{GRAPH}/servicePrincipals/{sp['id']}/appRoleAssignedTo",
                {"principalId": group_id, "resourceId": sp["id"], "appRoleId": DEFAULT_ROLE_ID},
            )
            self.out(f"  {group.name}: assigned")

    def add_member(self, product: Product, group_name: str, upn: str) -> None:
        if group_name not in {g.name for g in product.groups if not g.dynamic}:
            raise GraphError(f"{group_name!r} is not an assigned group of this product (dynamic groups fill themselves)")
        group = self.find_group(group_name)
        if group is None:
            raise GraphError(f"group {group_name!r} does not exist; run setup first")
        user = self.graph.call("GET", f"{GRAPH}/users/{odata_quote(upn)}?$select=id,userPrincipalName", allow_missing=True)
        if user is None:
            raise GraphError(f"no user {upn!r} in this tenant")
        if user["id"] in self.group_members(group["id"]):
            self.out(f"{upn} is already in {group_name}")
            return
        if not self.confirm(f"Add {user['userPrincipalName']} to {group_name}?"):
            return
        self.graph.call("POST", f"{GRAPH}/groups/{group['id']}/members/$ref", {"@odata.id": f"{GRAPH}/directoryObjects/{user['id']}"})
        self.out(f"added {user['userPrincipalName']} to {group_name}")

    # ── assignment required: check, enforce, roll back ────────────────────────────────────────────────
    def lost_access(self, product: Product) -> list[str]:
        """UPNs that signed in to the app in the window and would be refused once assignment is required."""
        app = self.require_app(product.sign_in_app)
        sp = self.require_sp(app)
        allowed: set[str] = set()
        for assignment in self.assignments(sp["id"]):
            if assignment.get("principalType") == "User":
                allowed.add(assignment["principalId"])
        for group in product.groups:
            found = self.find_group(group.name)
            if found is None:
                raise GraphError(f"group {group.name!r} is missing; run setup before check")
            allowed |= self.group_members(found["id"])
        since = self.now() - dt.timedelta(days=SIGNIN_WINDOW_DAYS)
        seen = {s["userId"]: s.get("userPrincipalName") or s["userId"] for s in self.successful_signins(app["appId"], since)}
        self.out(f"{app['displayName']}: {len(seen)} user(s) signed in since {since:%Y-%m-%d}; {len(allowed)} allowed by groups or direct assignment")
        lost = sorted(upn for uid, upn in seen.items() if uid not in allowed)
        for upn in lost:
            self.out(f"  WOULD LOSE ACCESS: {upn}")
        return lost

    def enforce(self, product: Product, flag: bool) -> None:
        app = self.require_app(product.sign_in_app)
        sp = self.require_sp(app)
        if not flag:
            if not self.confirm(f"Set appRoleAssignmentRequired=false on {app['displayName']} (rollback)?"):
                return
        else:
            lost = self.lost_access(product)
            if lost:
                raise GraphError(f"{len(lost)} user(s) would lose access; add them with add-member (or confirm they must go) and check again")
            if not self.confirm(f"Set appRoleAssignmentRequired=true on {app['displayName']}?"):
                return
        self.graph.call("PATCH", f"{GRAPH}/servicePrincipals/{sp['id']}", {"appRoleAssignmentRequired": flag})
        self.out(f"{app['displayName']}: appRoleAssignmentRequired={flag}")

    # ── secret rotation ───────────────────────────────────────────────────────────────────────────────
    def rotate(self, product: Product, cluster: str, services: list[str], out_dir: str) -> int:
        app = self.require_app(product.sign_in_app)
        old_ids = [c["keyId"] for c in app.get("passwordCredentials") or []]
        self.out(f"{app['displayName']}: existing secret keyIds {old_ids or 'none'}")
        self.out(f"  bundle {product.bundle} key {CLIENT_SECRET_KEY}; restart {cluster}: {', '.join(services)}")
        if not self.confirm("Add a new client secret (valid 180 days) and write it to the bundle?"):
            return 1
        expiry = self.now() + dt.timedelta(days=SECRET_LIFETIME_DAYS)
        new = self.graph.call(
            "POST",
            f"{GRAPH}/applications/{app['id']}/addPassword",
            {"passwordCredential": {"displayName": f"rotated {self.now():%Y-%m-%d}", "endDateTime": iso(expiry)}},
        )
        new_id, ends, secret = new["keyId"], new["endDateTime"], new["secretText"]
        self.out(f"  new secret keyId {new_id}, ends {ends}, length {len(secret)} (value not shown)")
        try:
            bundle = json.loads(self.aws.get_secret(product.bundle))
            previous = bundle.get(CLIENT_SECRET_KEY)
            bundle[CLIENT_SECRET_KEY] = secret
            self.aws.put_secret(product.bundle, json.dumps(bundle))
        except Exception:
            # The new secret was never stored, so nothing uses it: remove it so no orphan secret is left behind.
            self.graph.call("POST", f"{GRAPH}/applications/{app['id']}/removePassword", {"keyId": new_id})
            raise
        self.out(f"  bundle written: key {CLIENT_SECRET_KEY}, length {len(bundle[CLIENT_SECRET_KEY])}")
        del secret, bundle  # no reference kept past this point

        if not self.confirm(f"Restart {', '.join(services)} now (rolling, old tasks keep the old secret until replaced)?"):
            self.out("Stopped before restart. Old secret still valid; no removal done. Restart later, then verify.")
            return 1
        for service in services:
            self.aws.restart(cluster, service)
        for service in services:
            self.aws.wait_stable(cluster, service)
        restarted = self.now()
        self.out("  services stable")

        if not self.confirm(f"Sign in to {app['displayName']} now (dev URL). Did sign-in work?"):
            return self.rollback_rotation(product, app, cluster, services, previous, new_id)
        if not self.signed_in_after(app["appId"], restarted):
            self.out("  no successful sign-in to the app is in the sign-in log yet (logs can lag a few minutes).")
            return self.rollback_rotation(product, app, cluster, services, previous, new_id)

        self.out(f"Old keyIds to remove: {old_ids or 'none'}")
        if old_ids and self.confirm("Remove the old secret(s) now?"):
            for old in old_ids:
                self.graph.call("POST", f"{GRAPH}/applications/{app['id']}/removePassword", {"keyId": old})
                self.out(f"  removed old keyId {old}")
        due = dt.datetime.fromisoformat(ends.replace("Z", "+00:00")) - dt.timedelta(days=ROTATE_BEFORE_EXPIRY_DAYS)
        path = write_calendar(out_dir, app["displayName"], due, ends)
        self.out(f"Next rotation due {due:%Y-%m-%d} (30 days before {ends}). Calendar file: {path}")
        return 0

    def rollback_rotation(self, product: Product, app: dict, cluster: str, services: list[str], previous: str | None, new_id: str) -> int:
        if previous is None:
            self.out("Rollback impossible: the bundle had no previous value. Old secret still valid in Entra; nothing removed.")
            return 1
        bundle = json.loads(self.aws.get_secret(product.bundle))
        bundle[CLIENT_SECRET_KEY] = previous
        self.aws.put_secret(product.bundle, json.dumps(bundle))
        del bundle, previous
        for service in services:
            self.aws.restart(cluster, service)
        for service in services:
            self.aws.wait_stable(cluster, service)
        self.graph.call("POST", f"{GRAPH}/applications/{app['id']}/removePassword", {"keyId": new_id})
        self.out(f"Rolled back: previous value restored, services restarted, new keyId {new_id} removed.")
        return 1

    def signed_in_after(self, app_id: str, since: dt.datetime, attempts: int = 10) -> bool:
        for attempt in range(attempts):
            if self.successful_signins(app_id, since):
                return True
            if attempt < attempts - 1:
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
        p.add_argument("--env", required=True, choices=["dev", "prod"])

    product_args(sub.add_parser("status", help="read-only: state of the sign-in app"))
    product_args(sub.add_parser("setup", help="create groups and assign them to the app"))
    p = sub.add_parser("add-member", help="add a guest or user to an assigned group")
    product_args(p)
    p.add_argument("--group", required=True)
    p.add_argument("--upn", required=True)
    product_args(sub.add_parser("check", help="read-only: who would lose access"))
    product_args(sub.add_parser("enforce", help="require assignment (runs check first)"))
    product_args(sub.add_parser("rollback", help="turn assignment requirement off"))
    p = sub.add_parser("rotate", help="rotate the sign-in app client secret")
    product_args(p)
    p.add_argument("--cluster", required=True)
    p.add_argument("--services", required=True, help="comma-separated ECS service names that read the bundle")
    p.add_argument("--out-dir", required=True, help="directory OUTSIDE any git repository for the calendar file")
    p = sub.add_parser("notes", help="set Notes (repo link) on the known apps")
    p.add_argument("--force", action="store_true", help="replace Notes that are already set")
    p = sub.add_parser("lock-app", help="application instance property lock on one app")
    p.add_argument("--name", required=True)
    return parser


def main(argv: list[str] | None = None, graph=None, aws=None, hygiene: Hygiene | None = None) -> int:
    args = build_parser().parse_args(argv)
    h = hygiene or Hygiene(graph or GraphClient(), aws or AwsClient())
    if args.command == "notes":
        h.notes(args.force)
        return 0
    if args.command == "lock-app":
        h.lock_app(args.name)
        return 0
    product = PRODUCTS.get((args.product, args.env))
    if product is None:
        raise SystemExit(f"no {args.product} {args.env} product configured")
    if args.command == "status":
        h.status(product)
    elif args.command == "setup":
        h.setup(product)
    elif args.command == "add-member":
        h.add_member(product, args.group, args.upn)
    elif args.command == "check":
        h.lost_access(product)
    elif args.command == "enforce":
        h.enforce(product, True)
    elif args.command == "rollback":
        h.enforce(product, False)
    elif args.command == "rotate":
        return h.rotate(product, args.cluster, [s for s in args.services.split(",") if s], args.out_dir)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (GraphError, AwsError) as err:
        sys.exit(f"hygiene: {err}")
