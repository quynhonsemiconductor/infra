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
  every app    no Mail.* application permission in Entra, no full_access_as_app, Sites.Selected not Sites.*.All, no unexpected owner,
               app instance property lock, notes, no implicit grant, https redirect URIs (loopback only on Dev apps, or on publicClient URIs),
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
import urllib.parse
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
SECRET_MAX_DAYS = 184  # "6 months or less": the longest calendar half-year (1 Jul - 31 Dec)
MAIL_APP_PERMISSION = re.compile(r"^Mail\.", re.I)
SITES_UNSCOPED = re.compile(r"^Sites\.(Read|ReadWrite|FullControl|Manage)\.All$")
# Microsoft Services tenant: service principals owned by it are Microsoft first-party apps (a public constant).
MICROSOFT_TENANT = "f8cdef31-a31e-4b4a-93e4-5f571e91255a"
LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}
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
    owners: list[str] = dataclasses.field(default_factory=list)

    @property
    def fails(self) -> list[Result]:
        return [r for r in self.results if r.status == FAIL]


RULES = {
    "audience": "Single tenant (signInAudience AzureADMyOrg)",
    "mail-app-permission": "No Mail.* / full_access_as_app application permission in Entra",
    "sites-scope": "Sites.Selected, not Sites.*.All",
    "unscoped-app-permission-only-on-service": "Application permissions only on Service apps",
    "owners": "No unexpected owner (an owner can add credentials)",
    "lock": "App instance property lock enabled",
    "notes": "Notes set",
    "implicit-grant": "No implicit grant",
    "redirect-uris": "HTTPS redirect URIs only (loopback: Dev web/SPA, or any public-client app)",
    "credential-expiry": "No credential expired or expiring within 30 days",
    "signin-delegated-only": "Sign-in app: only openid/profile/email/offline_access/User.Read",
    "signin-secret-lifetime": "Sign-in app: client secrets of 6 months or less (184 days)",
    "signin-assignment-required": "Sign-in app: enterprise app assignment required",
    "signin-no-mail-rbac": "Sign-in app: no Exchange Application Mail role",
    "service-no-secret": "Service app: no client secret",
    "service-no-delegated": "Service app: no delegated permissions",
    "service-mail-rbac-scoped": "Service app: Exchange Application Mail.* role only with a custom resource scope",
}
APPLIES = {
    "signin": {"signin-delegated-only", "signin-secret-lifetime", "signin-assignment-required", "signin-no-mail-rbac"},
    "service": {"service-no-secret", "service-no-delegated", "service-mail-rbac-scoped"},
}


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────


def parse_time(value: Optional[str]) -> Optional[dt.datetime]:
    if not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    # Graph prints 1 to 7 fractional digits; datetime.fromisoformat (before Python 3.11) accepts only 3 or 6.
    text = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), text, count=1)
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


def owner_name(owner: dict) -> str:
    return owner.get("userPrincipalName") or owner.get("displayName") or owner.get("id") or "(unnamed owner)"


def owner_label(owner: dict) -> str:
    return f"{owner_name(owner)} ({owner.get('type') or 'owner'})"


def owner_expected(owner: dict, expected: frozenset[str]) -> bool:
    """An owner is expected when its UPN, display name or object id is on the allow-list (--expected-owners)."""
    keys = {str(owner.get(f)).strip().lower() for f in ("userPrincipalName", "displayName", "id") if owner.get(f)}
    return bool(keys & expected)


def short(permission: str) -> str:
    return permission.split(": ", 1)[-1]


def all_credentials(app: dict) -> list[tuple[str, dict]]:
    return [("secret", c) for c in app.get("passwordCredentials") or []] + [
        ("certificate", c) for c in app.get("keyCredentials") or []
    ]


def cred_label(kind: str, cred: dict) -> str:
    return f"{kind} '{cred.get('displayName') or '(no name)'}' (keyId {cred.get('keyId', '?')})"


# ── rules ────────────────────────────────────────────────────────────────────────────────────────────────


def check_app(app: dict, by_object: dict, by_app: dict, exchange: Optional[dict], products: list[str], now: dt.datetime,
              expected_owners: frozenset[str] = frozenset()) -> AppReport:
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
    unexpected = [o for o in owners if not owner_expected(o, expected_owners)]
    add("owners", not unexpected, "; ".join(f"{owner_label(o)}" for o in unexpected),
        "Remove the owner " + ", ".join(owner_name(o) for o in unexpected) + "; manage through admin roles (an app owner can add credentials, a privilege path)")

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
        host = (urllib.parse.urlsplit(uri).hostname or "").lower()
        scheme = urllib.parse.urlsplit(uri).scheme.lower()
        loopback = host in LOOPBACK_HOSTS
        if "*" in uri:
            bad.append(f"{uri} ({where}, wildcard)")
        elif loopback and where == "public client" and scheme in ("http", "https"):
            continue  # RFC 8252: a native app listens on a loopback port; any environment
        elif loopback and env != "Dev":
            bad.append(f"{uri} ({where}, localhost on a non-Dev app)")
        elif scheme == "https":
            continue
        elif scheme == "http" and loopback and env == "Dev":
            continue
        else:
            bad.append(f"{uri} ({where}, not https)")
    add("redirect-uris", not bad, "; ".join(bad),
        "Remove or replace with exact HTTPS URIs: " + ", ".join(b.split(" (")[0] for b in bad) + (
            "" if env == "Dev" else " (loopback is allowed on web/SPA URIs of Dev apps only; on publicClient URIs of any app)"))

    problems = []
    fixes = []
    for ctype, cred in all_credentials(app):
        end = parse_time(cred.get("endDateTime"))
        if end is None:
            problems.append(f"{cred_label(ctype, cred)} has an unreadable end date {cred.get('endDateTime')!r}")
            fixes.append(f"check the {ctype} {cred.get('keyId', '?')} by hand")
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
        delegated = sorted(perms["delegated"]["consented"] | perms["delegated"]["declared"])
        add("service-no-delegated", not delegated, "delegated permissions: " + ", ".join(short(p) for p in delegated),
            "Remove " + ", ".join(short(p) for p in delegated) + " (a Service app is a worker; new registrations get delegated User.Read by default)")
    else:
        results.append(Result("service-no-secret", NA))
        results.append(Result("service-no-delegated", NA))

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
        owners=[owner_label(o) for o in owners],
    )


def _values(item: dict, fields: tuple[str, ...]) -> set[str]:
    """Lower-cased non-empty field values; None, "" and "none" must never be a match key (two unrelated blanks would match)."""
    out = set()
    for field in fields:
        value = item.get(field)
        if value is None:
            continue
        text = str(value).strip().lower()
        if text and text not in ("none", "null"):
            out.add(text)
    return out


def exchange_assignments(app: dict, exchange: dict) -> list[dict]:
    """Role assignments whose assignee is this app's service principal (matched on object id, app id or name)."""
    keys = _values({"a": app.get("appId"), "b": (app.get("servicePrincipal") or {}).get("id"), "c": app.get("displayName")}, ("a", "b", "c"))
    ids = set(keys)
    for sp in exchange.get("servicePrincipals") or []:
        values = _values(sp, ("AppId", "ObjectId", "Identity", "DisplayName", "Name"))
        if keys & values:
            ids |= values
    return [a for a in exchange.get("roleAssignments") or [] if _values(a, ("RoleAssignee", "RoleAssigneeName")) & ids]


def scope_filter(assignment: dict, exchange: dict) -> str:
    name = assignment.get("CustomResourceScope")
    if not name:
        return ""
    for scope in exchange.get("managementScopes") or []:
        if scope.get("Name") == name:
            return (scope.get("RecipientFilter") or "").strip()
    return ""


def check_external(sp: dict, by_object: dict) -> dict:
    """A service principal that holds Graph / Exchange application roles but has no app registration in this tenant:
    a third-party or multi-tenant app, or a managed identity. Microsoft first-party apps are shown, not graded."""
    owner = (sp.get("appOwnerOrganizationId") or "").lower()
    if owner == MICROSOFT_TENANT:
        kind = "microsoft"
    elif sp.get("servicePrincipalType") == "ManagedIdentity":
        kind = "managed-identity"
    else:
        kind = "third-party"
    perms = set()
    for assignment in sp.get("appRoleAssignments") or []:
        resource = by_object.get(assignment.get("resourceId"))
        perms.add(f"{(resource or {}).get('displayName') or 'resource'}: {role_name(resource, assignment.get('appRoleId', ''))}")
    results: list[Result] = []
    if kind != "microsoft":
        mail = sorted(p for p in perms if MAIL_APP_PERMISSION.match(short(p)) or short(p) == "full_access_as_app")
        sites = sorted(p for p in perms if SITES_UNSCOPED.match(short(p)))
        fix_tail = "Remove the app role assignment (Enterprise applications > this app > Permissions), or delete the service principal if nothing uses it"
        results.append(Result("mail-app-permission", FAIL if mail else PASS, ", ".join(short(p) for p in mail),
                              f"{fix_tail}: {', '.join(short(p) for p in mail)}" if mail else ""))
        results.append(Result("sites-scope", FAIL if sites else PASS, ", ".join(short(p) for p in sites),
                              f"{fix_tail}: {', '.join(short(p) for p in sites)} (Sites.Selected is the scoped form)" if sites else ""))
    return {
        "name": sp.get("displayName") or "(no name)", "app_id": sp.get("appId", ""), "object_id": sp.get("id", ""), "kind": kind,
        "ownerTenant": owner, "accountEnabled": sp.get("accountEnabled"), "app_permissions": sorted(perms),
        "results": [dataclasses.asdict(r) for r in results],
        "failCount": sum(1 for r in results if r.status == FAIL),
    }


# ── report ───────────────────────────────────────────────────────────────────────────────────────────────


def build(graph: dict, exchange: Optional[dict], products: list[str], now: dt.datetime, expected_owners: frozenset[str] = frozenset()) -> dict:
    by_object, by_app = index_resources(graph.get("resources") or {})
    expected_owners = frozenset(str(o).strip().lower() for o in expected_owners)
    reports = [check_app(a, by_object, by_app, exchange, products, now, expected_owners) for a in graph.get("applications") or []]
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

    external = sorted((check_external(p, by_object) for p in graph.get("externalPrincipals") or []),
                      key=lambda e: (e["kind"] == "microsoft", e["kind"], e["name"]))

    return {
        "generatedAt": now.isoformat(),
        "exchangeCollected": exchange is not None,
        "collectionNotes": graph.get("collectionNotes") or [],
        "apps": [dataclasses.asdict(r) | {"failCount": len(r.fails)} for r in reports],
        "externalPrincipals": external,
        "missingApps": missing,
        "unmatchedExchangeMailAssignments": unmatched,
        "summary": {
            "apps": len(reports),
            "appsWithFailures": sum(1 for r in reports if r.fails),
            "failures": sum(len(r.fails) for r in reports) + sum(e["failCount"] for e in external),
            "externalPrincipals": sum(1 for e in external if e["kind"] != "microsoft"),
            "externalFailures": sum(e["failCount"] for e in external),
            "microsoftFirstParty": sum(1 for e in external if e["kind"] == "microsoft"),
            "unknownApps": sum(1 for r in reports if r.kind == "unknown"),
        },
    }


def md_cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def render_markdown(report: dict) -> str:
    out = ["# Entra app registration audit", ""]
    summary = report["summary"]
    summary.setdefault("externalPrincipals", 0)
    out.append(f"Generated {report['generatedAt']}. Read-only. Standard: HYBRID-INFRA-PLAN section 7.4 (decided 2026-10-18).")
    out.append("")
    out.append(
        f"**{summary['apps']} app(s), {summary['appsWithFailures']} with failures, {summary['failures']} failing rule(s)**; "
        f"{summary['unknownApps']} app(s) do not follow the naming and are listed separately. "
        f"{summary['externalPrincipals']} service principal(s) without an app registration here ({summary['externalFailures']} failing rule(s))."
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

    third = [e for e in report.get("externalPrincipals", []) if e["kind"] != "microsoft"]
    first = [e for e in report.get("externalPrincipals", []) if e["kind"] == "microsoft"]
    out.append("## Service principals with no app registration in this tenant")
    out.append("")
    out.append("Third-party / multi-tenant apps and managed identities that hold Graph or Exchange application permissions "
               "(from `appRoleAssignedTo` on those two resources; other resources are not scanned).")
    out.append("")
    if third:
        out += ["| Name | Kind | Owner tenant | Application permissions | Failing rules |", "| :--- | :--- | :--- | :--- | :--- |"]
        for e in third:
            failing = ", ".join(r["rule"] for r in e["results"] if r["status"] == FAIL) or "none"
            out.append(f"| {md_cell(e['name'])} | {e['kind']} | {e['ownerTenant'] or '-'} | {md_cell(', '.join(e['app_permissions']))} | {failing} |")
        for e in third:
            for r in e["results"]:
                if r["status"] == FAIL:
                    out.append(f"\n**{e['name']}** `{r['rule']}`: {r['fix']}")
    else:
        out.append("None.")
    out.append("")
    out.append("### Microsoft first-party (information only, not graded)")
    out.append("")
    out += [f"- {md_cell(e['name'])}: {md_cell(', '.join(e['app_permissions']))}" for e in first] or ["None."]
    out.append("")

    out.append("## Per app")
    for app in report["apps"]:
        out += ["", f"### {app['name']}", ""]
        out.append(f"{app['kind']}" + (f", {app['product']} {app['env']}" if app["kind"] != "unknown" else "") + f" · appId `{app['app_id']}` · objectId `{app['object_id']}`")
        if app["app_permissions"]:
            out.append(f"\nApplication permissions: {', '.join(app['app_permissions'])}")
        if app["delegated_permissions"]:
            out.append(f"\nDelegated permissions: {', '.join(app['delegated_permissions'])}")
        out.append(f"\nOwners (information): {', '.join(app['owners']) if app['owners'] else 'none'}")
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
    ap.add_argument("--expected-owners", default="", help="comma-separated UPNs, display names or object ids that may own an app (default: none)")
    ap.add_argument("--now", help="ISO time to judge expiry at (default: now; for tests)")
    args = ap.parse_args(argv)
    if sys.version_info < (3, 10):
        print(f"Python 3.10 or newer is required (this is {sys.version.split()[0]}). On macOS: brew install python, then run python3.13 or similar.", file=sys.stderr)
        return 2

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

    expected = frozenset(o.strip().lower() for o in args.expected_owners.split(",") if o.strip())
    report = build(graph, exchange, [p.strip() for p in args.products.split(",") if p.strip()], now, expected)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "entra-audit-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    markdown = render_markdown(report)
    (out_dir / "entra-audit-report.md").write_text(markdown, encoding="utf-8")
    print(markdown)
    print(f"written: {out_dir / 'entra-audit-report.md'} and entra-audit-report.json", file=sys.stderr)
    return 1 if report["summary"]["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
