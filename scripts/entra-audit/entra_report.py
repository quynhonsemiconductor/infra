#!/usr/bin/env python3
"""Turn the collected Entra (and optionally Exchange) data into a pass/fail report against the QNSC app-registration standard.

Input is what `entra-audit.sh` and `exchange-rbac-audit.ps1` wrote: metadata only (ids, names, permissions, credential
key ids and dates), never a secret value. This script reads those files and writes a markdown report and a JSON report;
it makes no network call and needs nothing but Python 3.10+.

    python3 entra_report.py DIR                      # DIR holds graph.json (and exchange.json if it was collected)
    python3 entra_report.py --graph g.json --exchange e.json --out DIR

The standard (HYBRID-INFRA-PLAN section 7.4, decided 2026-10-18):

  per product per environment TWO apps
    sign-in   "<Product> <Env>"           delegated only (openid, profile, email, offline_access, User.Read); single tenant
    service   "<Product> <Env> Service"   worker only; certificate only; application permissions; mail through Exchange
                                          RBAC for Applications (Application Mail.Send, scoped to the product mailbox)
  every app    no Mail.* application permission in Entra, no full_access_as_app, Sites.Selected not Sites.*.All, two owners,
               app instance property lock, notes, no implicit grant, https redirect URIs (http://localhost only on Dev apps),
               signInAudience AzureADMyOrg, nothing expiring within 30 days
  service app  no client secret
  sign-in app  secrets of 6 months or less; enterprise app "assignment required"; no application permissions

Apps are mapped to product and environment by display name. An app that does not follow the naming (an old SSO app, a
connector) is reported as UNKNOWN and gets only the rules that hold for every app.

Exit status: 0 no FAIL, 1 at least one FAIL, 2 unusable input.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import pathlib
import re
import sys
from typing import Any, Optional

PASS, FAIL, NA, SKIP = "PASS", "FAIL", "N/A", "SKIP"

DEFAULT_PRODUCTS = ["Rova", "OpsHub", "KB", "LMS"]
# Names the plan and the tenant have used for a product's apps besides the short name.
ALIASES = {
    "opshub": ["QNSC OpsHub"],
    "kb": ["QNSC KB", "QNSC Knowledge Base", "Knowledge Base"],
    "lms": ["QNSC Academy", "Academy", "QNSC LMS"],
    "rova": ["QNSC Rova"],
}
ENVIRONMENTS = {
    "dev": "Dev", "develop": "Dev", "development": "Dev", "local": "Dev",
    "prod": "Prod", "production": "Prod",
    "staging": "Staging", "stage": "Staging", "test": "Test", "uat": "UAT",
}

SIGNIN_DELEGATED = {"openid", "profile", "email", "offline_access", "User.Read"}
EXPIRY_WARNING_DAYS = 30
SECRET_MAX_DAYS = 183  # "6 months or less"
MAIL_APP_PERMISSION = re.compile(r"^Mail\.", re.I)
SITES_UNSCOPED = re.compile(r"^Sites\.(Read|ReadWrite|FullControl|Manage)\.All$")
EXCHANGE_MAIL_ROLE = re.compile(r"^Application Mail\.", re.I)


# ── model ────────────────────────────────────────────────────────────────────────────────────────────────


@dataclasses.dataclass
class Result:
    rule: str
    status: str
    detail: str = ""
    fix: str = ""


@dataclasses.dataclass
class AppReport:
    name: str
    app_id: str
    object_id: str
    kind: str  # signin | service | unknown
    product: str
    env: str
    results: list[Result]
    app_permissions: list[str]
    delegated_permissions: list[str]

    @property
    def fails(self) -> list[Result]:
        return [r for r in self.results if r.status == FAIL]


RULES = {
    "audience": "Single tenant (signInAudience AzureADMyOrg)",
    "mail-app-permission": "No Mail.* / full_access_as_app application permission in Entra",
    "sites-scope": "Sites.Selected, not Sites.*.All",
    "unscoped-app-permission-only-on-service": "Application permissions only on Service apps",
    "owners": "At least 2 owners",
    "lock": "App instance property lock enabled",
    "notes": "Notes set",
    "implicit-grant": "No implicit grant",
    "redirect-uris": "HTTPS redirect URIs only (http://localhost only on Dev)",
    "credential-expiry": "No credential expired or expiring within 30 days",
    "signin-delegated-only": "Sign-in app: only openid/profile/email/offline_access/User.Read",
    "signin-secret-lifetime": "Sign-in app: client secrets of 6 months or less",
    "signin-assignment-required": "Sign-in app: enterprise app assignment required",
    "signin-no-mail-rbac": "Sign-in app: no Exchange Application Mail role",
    "service-no-secret": "Service app: no client secret",
    "service-mail-rbac-scoped": "Service app: Exchange Application Mail.* role only with a custom resource scope",
}
APPLIES = {
    "signin": {"signin-delegated-only", "signin-secret-lifetime", "signin-assignment-required", "signin-no-mail-rbac"},
    "service": {"service-no-secret", "service-mail-rbac-scoped"},
}


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────


def parse_time(value: Optional[str]) -> Optional[dt.datetime]:
    if not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    text = re.sub(r"(\.\d{6})\d+", r"\1", text)  # Graph can print 7 fractional digits
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)


def classify(display_name: str, products: list[str]) -> tuple[str, str, str]:
    """(kind, product, env) from the display name; ("unknown", "", "") when it does not follow the naming."""
    names = []
    for product in products:
        names.append((product, product))
        for alias in ALIASES.get(product.lower(), []):
            names.append((product, alias))
    names.sort(key=lambda pair: -len(pair[1]))  # longest first: "QNSC OpsHub" before "OpsHub"
    env_words = "|".join(sorted(ENVIRONMENTS, key=len, reverse=True))
    for product, label in names:
        match = re.fullmatch(rf"\s*{re.escape(label)}\s+({env_words})(\s+Service)?\s*", display_name, re.I)
        if match:
            return ("service" if match.group(2) else "signin"), product, ENVIRONMENTS[match.group(1).lower()]
    return "unknown", "", ""


def index_resources(resources: dict[str, Any]) -> tuple[dict[str, dict], dict[str, dict]]:
    by_object = {key: value for key, value in resources.items()}
    by_app = {value.get("appId"): value for value in resources.values() if value.get("appId")}
    return by_object, by_app


def role_name(resource: Optional[dict], role_id: str) -> str:
    if resource:
        for role in resource.get("appRoles") or []:
            if role.get("id") == role_id:
                return role.get("value") or role.get("displayName") or role_id
    return f"unresolved-role({role_id})"


def scope_name(resource: Optional[dict], scope_id: str) -> str:
    if resource:
        for scope in resource.get("oauth2PermissionScopes") or []:
            if scope.get("id") == scope_id:
                return scope.get("value") or scope_id
    return f"unresolved-scope({scope_id})"


def permissions_of(app: dict, by_object: dict, by_app: dict) -> dict[str, dict[str, set[str]]]:
    """{"app": {"consented": {...}, "declared": {...}}, "delegated": {...}} as "Resource: Permission" strings."""
    out = {"app": {"consented": set(), "declared": set()}, "delegated": {"consented": set(), "declared": set()}}
    sp = app.get("servicePrincipal") or {}
    for assignment in sp.get("appRoleAssignments") or []:
        resource = by_object.get(assignment.get("resourceId"))
        label = (resource or {}).get("displayName") or assignment.get("resourceDisplayName") or "resource"
        out["app"]["consented"].add(f"{label}: {role_name(resource, assignment.get('appRoleId', ''))}")
    for grant in sp.get("oauth2PermissionGrants") or []:
        resource = by_object.get(grant.get("resourceId"))
        label = (resource or {}).get("displayName") or "resource"
        for scope in (grant.get("scope") or "").split():
            out["delegated"]["consented"].add(f"{label}: {scope}")
    for access in app.get("requiredResourceAccess") or []:
        resource = by_app.get(access.get("resourceAppId"))
        label = (resource or {}).get("displayName") or "resource"
        for item in access.get("resourceAccess") or []:
            if item.get("type") == "Role":
                out["app"]["declared"].add(f"{label}: {role_name(resource, item.get('id', ''))}")
            else:
                out["delegated"]["declared"].add(f"{label}: {scope_name(resource, item.get('id', ''))}")
    return out


def short(permission: str) -> str:
    return permission.split(": ", 1)[-1]


def all_credentials(app: dict) -> list[tuple[str, dict]]:
    return [("secret", c) for c in app.get("passwordCredentials") or []] + [
        ("certificate", c) for c in app.get("keyCredentials") or []
    ]


def cred_label(kind: str, cred: dict) -> str:
    return f"{kind} '{cred.get('displayName') or '(no name)'}' (keyId {cred.get('keyId', '?')})"


# ── rules ────────────────────────────────────────────────────────────────────────────────────────────────


def check_app(app: dict, by_object: dict, by_app: dict, exchange: Optional[dict], products: list[str], now: dt.datetime) -> AppReport:
    name = app.get("displayName") or "(no name)"
    kind, product, env = classify(name, products)
    perms = permissions_of(app, by_object, by_app)
    app_perms = perms["app"]["consented"] | perms["app"]["declared"]
    results: list[Result] = []

    def add(rule: str, ok: Optional[bool], detail: str = "", fix: str = "") -> None:
        status = NA if ok is None else (PASS if ok else FAIL)
        results.append(Result(rule, status, detail if status == FAIL else "", fix if status == FAIL else ""))

    # every app -----------------------------------------------------------------------------------------
    audience = app.get("signInAudience")
    add("audience", audience == "AzureADMyOrg", f"signInAudience is {audience!r}",
        "Authentication > Supported account types: set 'Accounts in this organizational directory only'")

    mail = sorted(p for p in app_perms if MAIL_APP_PERMISSION.match(short(p)) or short(p) == "full_access_as_app")
    consented_mail = {p for p in mail if p in perms["app"]["consented"]}
    if mail:
        add("mail-app-permission", False,
            "; ".join(f"{short(p)} ({'CONSENTED' if p in consented_mail else 'declared, not consented'})" for p in mail),
            "Remove " + ", ".join(short(p) for p in mail) + " (API permissions; revoke admin consent first) and send through "
            "Exchange RBAC for Applications: Application Mail.Send with a management scope on the product mailbox")
    else:
        add("mail-app-permission", True)

    sites = sorted(p for p in app_perms if SITES_UNSCOPED.match(short(p)))
    add("sites-scope", not sites, ", ".join(short(p) for p in sites),
        "Replace " + ", ".join(short(p) for p in sites) + " with Sites.Selected and grant the app access to the one site")

    others = sorted(p for p in app_perms if p not in mail and p not in sites)
    if kind == "service":
        add("unscoped-app-permission-only-on-service", None)
    else:
        every = sorted(app_perms)
        add("unscoped-app-permission-only-on-service", not every,
            "application permissions on a " + ("sign-in" if kind == "signin" else "non-Service") + " app: " + ", ".join(short(p) for p in every),
            "Move " + ", ".join(short(p) for p in every) + " to the matching '<Product> <Env> Service' app and remove them here")

    owners = app.get("owners") or []
    add("owners", len(owners) >= 2, f"{len(owners)} owner(s)", "Add a second owner (Owners blade); prefer two people, not a group or a service principal")

    lock = app.get("servicePrincipalLockConfiguration") or {}
    detail = "servicePrincipalLockConfiguration is not enabled"
    add("lock", bool(lock.get("isEnabled")), detail, "Authentication > App instance property lock: enable it and lock all properties")
    if lock.get("isEnabled") and not lock.get("allProperties"):
        results[-1].detail = "enabled, but 'lock all properties' is off (not a failure)"

    add("notes", bool((app.get("notes") or "").strip()), "Notes is empty", "Set Notes to the repository that owns this app (Branding & properties > Internal notes)")

    web = app.get("web") or {}
    implicit = web.get("implicitGrantSettings") or {}
    on = [k for k in ("enableIdTokenIssuance", "enableAccessTokenIssuance") if implicit.get(k)]
    add("implicit-grant", not on, "implicit grant enabled: " + ", ".join(on),
        "Authentication > Implicit grant and hybrid flows: untick both 'Access tokens' and 'ID tokens'")

    uris = [("web", u) for u in web.get("redirectUris") or []] + [("spa", u) for u in (app.get("spa") or {}).get("redirectUris") or []] + [
        ("public client", u) for u in (app.get("publicClient") or {}).get("redirectUris") or []
    ]
    bad = []
    for where, uri in uris:
        if uri.lower().startswith("https://") and "*" not in uri:
            continue
        if env == "Dev" and re.match(r"^http://localhost(:\d+)?(/|$)", uri, re.I):
            continue
        bad.append(f"{uri} ({where})")
    add("redirect-uris", not bad, "; ".join(bad),
        "Remove or replace with exact HTTPS URIs: " + ", ".join(b.split(" (")[0] for b in bad) + (
            "" if env == "Dev" else " (http://localhost is allowed only on Dev apps)"))

    problems = []
    fixes = []
    for ctype, cred in all_credentials(app):
        end = parse_time(cred.get("endDateTime"))
        if end is None:
            continue
        days = (end - now).days
        if end < now:
            problems.append(f"{cred_label(ctype, cred)} EXPIRED {end.date()}")
            fixes.append(f"remove the expired {ctype} {cred.get('keyId', '?')}")
        elif end < now + dt.timedelta(days=EXPIRY_WARNING_DAYS):
            problems.append(f"{cred_label(ctype, cred)} expires {end.date()} (in {days} days)")
            fixes.append(f"rotate the {ctype} {cred.get('keyId', '?')} (add the new one first, then remove it)")
    joined = "; ".join(fixes)
    add("credential-expiry", not problems, "; ".join(problems), joined[:1].upper() + joined[1:])

    # sign-in apps ------------------------------------------------------------------------------------------
    if kind == "signin":
        extra = sorted(p for p in perms["delegated"]["consented"] | perms["delegated"]["declared"] if short(p) not in SIGNIN_DELEGATED)
        add("signin-delegated-only", not extra, "delegated permissions beyond the standard: " + ", ".join(extra),
            "Remove " + ", ".join(short(p) for p in extra) + " (a sign-in app holds only openid, profile, email, offline_access, User.Read)")

        long = []
        for cred in app.get("passwordCredentials") or []:
            start, end = parse_time(cred.get("startDateTime")), parse_time(cred.get("endDateTime"))
            if start and end and (end - start).days > SECRET_MAX_DAYS:
                long.append(f"{cred_label('secret', cred)} valid {(end - start).days} days")
        add("signin-secret-lifetime", not long, "; ".join(long), "Replace with a secret of 6 months or less (-previous rotation pattern), then remove the long one")

        sp = app.get("servicePrincipal")
        if sp is None:
            add("signin-assignment-required", False, "no enterprise application (service principal) found for this app",
                "Create the enterprise application, set 'Assignment required' to Yes and assign Entra groups")
        else:
            add("signin-assignment-required", bool(sp.get("appRoleAssignmentRequired")), "appRoleAssignmentRequired is false",
                "Enterprise applications > Properties > 'Assignment required?': Yes; then assign the Entra groups")
    else:
        for rule in APPLIES["signin"] - {"signin-no-mail-rbac"}:
            results.append(Result(rule, NA))
    results.append(Result("signin-no-mail-rbac", NA))  # replaced below for sign-in apps when exchange.json exists

    # service apps ------------------------------------------------------------------------------------------
    if kind == "service":
        secrets = app.get("passwordCredentials") or []
        add("service-no-secret", not secrets, "client secret(s): " + ", ".join(cred_label("secret", c) for c in secrets),
            "Remove the client secret(s); use a certificate (or a federated credential on k3s)")
    else:
        results.append(Result("service-no-secret", NA))

    # Exchange RBAC (needs exchange.json) -------------------------------------------------------------------
    mine = exchange_assignments(app, exchange) if exchange else None
    mail_roles = [a for a in (mine or []) if EXCHANGE_MAIL_ROLE.match(a.get("Role") or "")]
    if kind == "signin":
        index = next(i for i, r in enumerate(results) if r.rule == "signin-no-mail-rbac")
        if mine is None:
            results[index] = Result("signin-no-mail-rbac", SKIP, "exchange.json not collected")
        elif mail_roles:
            results[index] = Result("signin-no-mail-rbac", FAIL, ", ".join(a["Role"] for a in mail_roles),
                                    "Move the Exchange role assignment to the matching Service app (New assignment there, then remove this one)")
        else:
            results[index] = Result("signin-no-mail-rbac", PASS)
    if kind == "service":
        if mine is None:
            results.append(Result("service-mail-rbac-scoped", SKIP, "exchange.json not collected"))
        elif not mail_roles:
            results.append(Result("service-mail-rbac-scoped", NA))
        else:
            unscoped = [a for a in mail_roles if not scope_filter(a, exchange)]
            add("service-mail-rbac-scoped", not unscoped,
                "; ".join(f"{a['Role']} has {'no custom resource scope' if not a.get('CustomResourceScope') else 'scope ' + a['CustomResourceScope'] + ' without a recipient filter'}" for a in unscoped),
                "Remove the assignment and re-create it with -CustomResourceScope (a management scope filtered on the product mailbox's PrimarySmtpAddress)")
    else:
        if not any(r.rule == "service-mail-rbac-scoped" for r in results):
            results.append(Result("service-mail-rbac-scoped", NA))

    order = list(RULES)
    results.sort(key=lambda r: order.index(r.rule))
    return AppReport(
        name=name, app_id=app.get("appId", ""), object_id=app.get("id", ""), kind=kind, product=product, env=env, results=results,
        app_permissions=sorted(app_perms), delegated_permissions=sorted(perms["delegated"]["consented"] | perms["delegated"]["declared"]),
    )


def exchange_assignments(app: dict, exchange: dict) -> list[dict]:
    """Role assignments whose assignee is this app's service principal (matched on object id, app id or name)."""
    keys = {k.lower() for k in (app.get("appId"), (app.get("servicePrincipal") or {}).get("id"), app.get("displayName")) if k}
    ids = set()
    for sp in exchange.get("servicePrincipals") or []:
        values = {str(sp.get(f, "")).lower() for f in ("AppId", "ObjectId", "Identity", "DisplayName", "Name")}
        if keys & values:
            ids |= values
    ids |= keys
    out = []
    for assignment in exchange.get("roleAssignments") or []:
        assignee = {str(assignment.get(f, "")).lower() for f in ("RoleAssignee", "RoleAssigneeName")}
        if assignee & ids:
            out.append(assignment)
    return out


def scope_filter(assignment: dict, exchange: dict) -> str:
    name = assignment.get("CustomResourceScope")
    if not name:
        return ""
    for scope in exchange.get("managementScopes") or []:
        if scope.get("Name") == name:
            return (scope.get("RecipientFilter") or "").strip()
    return ""


# ── report ───────────────────────────────────────────────────────────────────────────────────────────────


def build(graph: dict, exchange: Optional[dict], products: list[str], now: dt.datetime) -> dict:
    by_object, by_app = index_resources(graph.get("resources") or {})
    reports = [check_app(a, by_object, by_app, exchange, products, now) for a in graph.get("applications") or []]
    reports.sort(key=lambda r: (r.kind == "unknown", r.product, r.env, r.kind != "signin", r.name))

    # Expected pair per (product, env): the other half is missing
    present = {(r.product, r.env, r.kind) for r in reports if r.kind != "unknown"}
    missing = []
    for product, env in sorted({(p, e) for p, e, _ in present}):
        for kind, label in (("signin", f"{product} {env}"), ("service", f"{product} {env} Service")):
            if (product, env, kind) not in present:
                missing.append(label)

    unmatched = []
    if exchange:
        claimed = {id(a) for app in graph.get("applications") or [] for a in exchange_assignments(app, exchange)}
        unmatched = [a for a in exchange.get("roleAssignments") or [] if id(a) not in claimed and EXCHANGE_MAIL_ROLE.match(a.get("Role") or "")]

    return {
        "generatedAt": now.isoformat(),
        "exchangeCollected": exchange is not None,
        "collectionNotes": graph.get("collectionNotes") or [],
        "apps": [dataclasses.asdict(r) | {"failCount": len(r.fails)} for r in reports],
        "missingApps": missing,
        "unmatchedExchangeMailAssignments": unmatched,
        "summary": {
            "apps": len(reports),
            "appsWithFailures": sum(1 for r in reports if r.fails),
            "failures": sum(len(r.fails) for r in reports),
            "unknownApps": sum(1 for r in reports if r.kind == "unknown"),
        },
    }


def md_cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def render_markdown(report: dict) -> str:
    out = ["# Entra app registration audit", ""]
    summary = report["summary"]
    out.append(f"Generated {report['generatedAt']}. Read-only. Standard: HYBRID-INFRA-PLAN section 7.4 (decided 2026-10-18).")
    out.append("")
    out.append(
        f"**{summary['apps']} app(s), {summary['appsWithFailures']} with failures, {summary['failures']} failing rule(s)**; "
        f"{summary['unknownApps']} app(s) do not follow the naming and are listed separately."
    )
    for note in report.get("collectionNotes", []):
        out += ["", f"> Collection note: {note}"]
    if not report["exchangeCollected"]:
        out.append("")
        out.append("> Exchange RBAC was not collected (no exchange.json): the mail-role rules show SKIP. Run `exchange-rbac-audit.ps1` and re-run the report.")
    out += ["", "## Overview", "", "| App | Kind | Product / env | Failing rules |", "| :--- | :--- | :--- | :--- |"]
    for app in report["apps"]:
        failing = ", ".join(r["rule"] for r in app["results"] if r["status"] == FAIL) or "none"
        where = f"{app['product']} / {app['env']}" if app["kind"] != "unknown" else "UNKNOWN"
        out.append(f"| {md_cell(app['name'])} | {app['kind']} | {where} | {md_cell(failing)} |")
    if report["missingApps"]:
        out += ["", "## Expected apps not found", ""]
        out += [f"- `{name}`" for name in report["missingApps"]]
    if report["unmatchedExchangeMailAssignments"]:
        out += ["", "## Exchange Application Mail roles that match no app", ""]
        out += [f"- {a.get('RoleAssigneeName') or a.get('RoleAssignee')}: {a.get('Role')} (scope: {a.get('CustomResourceScope') or 'NONE'})" for a in report["unmatchedExchangeMailAssignments"]]

    out += ["", "## Fix list", ""]
    any_fix = False
    for app in report["apps"]:
        fixes = [r for r in app["results"] if r["status"] == FAIL]
        if not fixes:
            continue
        any_fix = True
        out.append(f"**{app['name']}**" + ("" if app["kind"] != "unknown" else " (UNKNOWN, rename to the standard or retire)"))
        out += [f"- `{r['rule']}`: {r['fix']}" for r in fixes]
        out.append("")
    if not any_fix:
        out.append("Nothing to fix.")
        out.append("")

    out.append("## Per app")
    for app in report["apps"]:
        out += ["", f"### {app['name']}", ""]
        out.append(f"{app['kind']}" + (f", {app['product']} {app['env']}" if app["kind"] != "unknown" else "") + f" · appId `{app['app_id']}` · objectId `{app['object_id']}`")
        if app["app_permissions"]:
            out.append(f"\nApplication permissions: {', '.join(app['app_permissions'])}")
        if app["delegated_permissions"]:
            out.append(f"\nDelegated permissions: {', '.join(app['delegated_permissions'])}")
        out += ["", "| Rule | Result | Detail |", "| :--- | :--- | :--- |"]
        for r in app["results"]:
            out.append(f"| {RULES[r['rule']]} | **{r['status']}** | {md_cell(r['detail'])} |")
    return "\n".join(out) + "\n"


def load(path: pathlib.Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read {path}: {error}") from error
    return data


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dir", nargs="?", help="directory with graph.json (and exchange.json); the report is written there")
    ap.add_argument("--graph")
    ap.add_argument("--exchange")
    ap.add_argument("--out", help="where to write the report (default: the directory)")
    ap.add_argument("--products", default=",".join(DEFAULT_PRODUCTS), help="product names that prefix the app display names")
    ap.add_argument("--now", help="ISO time to judge expiry at (default: now; for tests)")
    args = ap.parse_args(argv)

    base = pathlib.Path(args.dir) if args.dir else None
    graph_path = pathlib.Path(args.graph) if args.graph else (base / "graph.json" if base else None)
    if graph_path is None:
        ap.error("give a directory or --graph")
    exchange_path = pathlib.Path(args.exchange) if args.exchange else (base / "exchange.json" if base else None)
    out_dir = pathlib.Path(args.out) if args.out else (base or graph_path.parent)

    graph = load(graph_path)
    if not isinstance(graph.get("applications"), list):
        print(f"{graph_path}: no 'applications' array — was the collection complete?", file=sys.stderr)
        return 2
    if not graph["applications"]:
        print(f"{graph_path}: zero applications. Does this account have read access (Global Reader) to the right tenant?", file=sys.stderr)
        return 2
    exchange = load(exchange_path) if exchange_path and exchange_path.exists() else None
    now = parse_time(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
    if now is None:
        print("--now is not an ISO time", file=sys.stderr)
        return 2

    report = build(graph, exchange, [p.strip() for p in args.products.split(",") if p.strip()], now)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "entra-audit-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    markdown = render_markdown(report)
    (out_dir / "entra-audit-report.md").write_text(markdown, encoding="utf-8")
    print(markdown)
    print(f"written: {out_dir / 'entra-audit-report.md'} and entra-audit-report.json", file=sys.stderr)
    return 1 if report["summary"]["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
