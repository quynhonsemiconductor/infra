"""Tests for the Entra audit: the report rules on recorded fixtures (fabricated ids), the collector against a fake `az`,
the Exchange script against stand-in cmdlets, and the read-only guard.

    python3 -m unittest scripts/entra-audit/test_entra_audit.py
"""

from __future__ import annotations

import copy
import datetime as dt
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import entra_report as er  # noqa: E402

FIXTURES = HERE / "fixtures"
NOW = dt.datetime(2026, 10, 18, tzinfo=dt.timezone.utc)
GRAPH = json.loads((FIXTURES / "graph.fixture.json").read_text())
EXCHANGE = json.loads((FIXTURES / "exchange.fixture.json").read_text())
PRODUCTS = er.DEFAULT_PRODUCTS


def report(graph=GRAPH, exchange=EXCHANGE):
    return er.build(graph, exchange, PRODUCTS, NOW)


def app_report(name, graph=GRAPH, exchange=EXCHANGE):
    return next(a for a in report(graph, exchange)["apps"] if a["name"] == name)


def failing(app):
    return {r["rule"] for r in app["results"] if r["status"] == er.FAIL}


def status(app, rule):
    return next(r["status"] for r in app["results"] if r["rule"] == rule)


def modified(name, change):
    graph = copy.deepcopy(GRAPH)
    app = next(a for a in graph["applications"] if a["displayName"] == name)
    change(app)
    return graph


class Classification(unittest.TestCase):
    def test_names_map_to_kind_product_and_env(self):
        cases = {
            "Rova Prod": ("signin", "Rova", "Prod"),
            "Rova Prod Service": ("service", "Rova", "Prod"),
            "OpsHub Dev Service": ("service", "OpsHub", "Dev"),
            "QNSC OpsHub Production": ("signin", "OpsHub", "Prod"),
            "KB Develop Service": ("service", "KB", "Dev"),
            "Knowledge Base Prod": ("signin", "KB", "Prod"),
            "rova prod service": ("service", "Rova", "Prod"),
        }
        for name, expected in cases.items():
            self.assertEqual(er.classify(name, PRODUCTS), expected, name)

    def test_apps_that_do_not_follow_the_naming_are_unknown(self):
        for name in ["QNSC KB SSO", "Rova", "Rova Prod Worker", "Contoso Prod", "Rova Prod Service Extra"]:
            self.assertEqual(er.classify(name, PRODUCTS)[0], "unknown", name)


class FixtureReport(unittest.TestCase):
    def test_the_good_apps_pass_every_rule(self):
        for name in ["Rova Prod", "Rova Prod Service", "Rova Dev", "KB Prod"]:
            self.assertEqual(failing(app_report(name)), set(), name)

    def test_bad_sign_in_app(self):
        self.assertEqual(
            failing(app_report("OpsHub Prod")),
            {"audience", "unscoped-app-permission-only-on-service", "owners", "lock", "notes", "implicit-grant", "redirect-uris",
             "signin-delegated-only", "signin-secret-lifetime", "signin-assignment-required", "signin-no-mail-rbac"},
        )

    def test_bad_service_app(self):
        app = app_report("OpsHub Prod Service")
        self.assertEqual(failing(app), {"mail-app-permission", "sites-scope", "owners", "credential-expiry", "service-no-secret", "service-mail-rbac-scoped"})
        mail = next(r for r in app["results"] if r["rule"] == "mail-app-permission")
        self.assertIn("Mail.Send (CONSENTED)", mail["detail"])
        self.assertIn("Exchange RBAC", mail["fix"])
        expiry = next(r for r in app["results"] if r["rule"] == "credential-expiry")
        self.assertIn("expires 2026-10-28 (in 10 days)", expiry["detail"])
        self.assertIn("EXPIRED 2026-09-30", expiry["detail"])
        self.assertIn("c0000000-0000-4000-8000-000000000007", expiry["fix"])  # names the credential to act on

    def test_unknown_app_gets_only_the_universal_rules_and_is_listed_separately(self):
        app = app_report("QNSC KB SSO")
        self.assertEqual(app["kind"], "unknown")
        self.assertEqual(failing(app), {"mail-app-permission", "unscoped-app-permission-only-on-service"})
        self.assertEqual(status(app, "signin-assignment-required"), er.NA)
        self.assertEqual(status(app, "service-no-secret"), er.NA)
        self.assertEqual([a["name"] for a in report()["apps"]][-1], "QNSC KB SSO")  # sorted last

    def test_expected_apps_that_are_missing_are_listed(self):
        self.assertEqual(report()["missingApps"], ["KB Prod Service", "Rova Dev Service"])

    def test_exchange_assignment_matching_no_app_is_listed(self):
        unmatched = report()["unmatchedExchangeMailAssignments"]
        self.assertEqual([a["Name"] for a in unmatched], ["stray"])

    def test_without_exchange_data_the_mail_role_rules_skip_not_pass(self):
        r = er.build(GRAPH, None, PRODUCTS, NOW)
        service = next(a for a in r["apps"] if a["name"] == "OpsHub Prod Service")
        signin = next(a for a in r["apps"] if a["name"] == "OpsHub Prod")
        self.assertEqual(status(service, "service-mail-rbac-scoped"), er.SKIP)
        self.assertEqual(status(signin, "signin-no-mail-rbac"), er.SKIP)
        self.assertIn("Exchange RBAC was not collected", er.render_markdown(r))

    def test_markdown_has_overview_fix_list_and_a_row_per_rule(self):
        md = er.render_markdown(report())
        self.assertIn("## Overview", md)
        self.assertIn("## Fix list", md)
        self.assertIn("**OpsHub Prod Service**", md)
        self.assertIn("(UNKNOWN, rename to the standard or retire)", md)
        for rule in er.RULES.values():
            self.assertIn(rule, md)

    def test_every_failure_has_a_concrete_fix_line(self):
        for app in report()["apps"]:
            for result in app["results"]:
                if result["status"] == er.FAIL:
                    self.assertTrue(result["fix"].strip(), f"{app['name']} {result['rule']}")


class Rules(unittest.TestCase):
    def test_credential_expiry_boundary_is_30_days(self):
        def with_cert(days):
            def change(app):
                end = (NOW + dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
                app["keyCredentials"] = [{"keyId": "k", "displayName": "c", "startDateTime": "2025-01-01T00:00:00Z", "endDateTime": end}]
            return modified("Rova Prod Service", change)

        self.assertEqual(status(app_report("Rova Prod Service", with_cert(31)), "credential-expiry"), er.PASS)
        self.assertEqual(status(app_report("Rova Prod Service", with_cert(29)), "credential-expiry"), er.FAIL)

    def test_secret_lifetime_boundary_is_six_calendar_months(self):
        def with_secret(days):
            def change(app):
                start = dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc)
                app["passwordCredentials"] = [{"keyId": "k", "displayName": "s", "startDateTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                               "endDateTime": (start + dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")}]
            return modified("Rova Prod", change)

        self.assertEqual(status(app_report("Rova Prod", with_secret(184)), "signin-secret-lifetime"), er.PASS)  # 1 Jul - 31 Dec
        self.assertEqual(status(app_report("Rova Prod", with_secret(185)), "signin-secret-lifetime"), er.FAIL)

    def test_graph_timestamps_with_any_number_of_fractional_digits_parse(self):
        base = dt.datetime(2026, 10, 28, 10, 20, 30, tzinfo=dt.timezone.utc)
        cases = {".1": 100000, ".16": 160000, ".123": 123000, ".1234": 123400, ".12345": 123450, ".123456": 123456, ".1234567": 123456, "": 0}
        for fraction, micro in cases.items():
            self.assertEqual(er.parse_time(f"2026-10-28T10:20:30{fraction}Z"), base.replace(microsecond=micro), fraction)
        self.assertIsNone(er.parse_time("not a date"))

    def test_a_certificate_expiring_in_two_days_with_a_two_digit_fraction_fails(self):
        def change(app):
            app["keyCredentials"] = [{"keyId": "k", "displayName": "c", "startDateTime": "2025-01-01T00:00:00Z", "endDateTime": "2026-10-20T00:00:00.16Z"}]
        self.assertEqual(status(app_report("Rova Prod Service", modified("Rova Prod Service", change)), "credential-expiry"), er.FAIL)

    def test_an_unreadable_end_date_fails_instead_of_being_skipped(self):
        def change(app):
            app["keyCredentials"] = [{"keyId": "k", "displayName": "c", "endDateTime": "garbage"}]
        app = app_report("Rova Prod Service", modified("Rova Prod Service", change))
        result = next(r for r in app["results"] if r["rule"] == "credential-expiry")
        self.assertEqual(result["status"], er.FAIL)
        self.assertIn("unreadable end date", result["detail"])

    def test_http_localhost_is_allowed_on_dev_only(self):
        def add(app):
            app["web"]["redirectUris"] = ["http://localhost:3000/cb"]
        self.assertEqual(status(app_report("Rova Dev", modified("Rova Dev", add)), "redirect-uris"), er.PASS)
        self.assertEqual(status(app_report("Rova Prod", modified("Rova Prod", add)), "redirect-uris"), er.FAIL)

    def test_localhost_in_any_scheme_fails_on_non_dev_apps(self):
        for uri in ["https://localhost/cb", "https://localhost:8443/cb", "http://127.0.0.1/cb", "https://127.0.0.1/cb", "http://[::1]:5000/cb", "https://[::1]/cb"]:
            def add(app, uri=uri):
                app["web"]["redirectUris"] = [uri]
            self.assertEqual(status(app_report("Rova Prod", modified("Rova Prod", add)), "redirect-uris"), er.FAIL, uri)

    def test_dev_apps_may_use_https_localhost_and_http_loopback(self):
        for uri in ["https://localhost:8443/cb", "http://localhost:3000/cb", "http://127.0.0.1:3000/cb", "http://[::1]:3000/cb"]:
            def add(app, uri=uri):
                app["web"]["redirectUris"] = [uri]
            self.assertEqual(status(app_report("Rova Dev", modified("Rova Dev", add)), "redirect-uris"), er.PASS, uri)

    def test_other_http_uris_and_wildcards_fail_even_on_dev(self):
        for uri in ["http://dev.example.invalid/cb", "https://*.example.invalid/cb", "http://localhost.evil.invalid/cb"]:
            def add(app, uri=uri):
                app["web"]["redirectUris"] = [uri]
            self.assertEqual(status(app_report("Rova Dev", modified("Rova Dev", add)), "redirect-uris"), er.FAIL, uri)

    def test_spa_and_public_client_uris_are_checked_too(self):
        def add(app):
            app["spa"]["redirectUris"] = ["http://app.example.invalid"]
        self.assertEqual(status(app_report("Rova Prod", modified("Rova Prod", add)), "redirect-uris"), er.FAIL)

    def test_a_declared_but_unconsented_mail_permission_still_fails(self):
        def declare(app):
            app["requiredResourceAccess"] = [{"resourceAppId": "00000003-0000-0000-c000-000000000000",
                                              "resourceAccess": [{"id": "f0000000-0000-4000-8000-000000000001", "type": "Role"}]}]
        app = app_report("Rova Prod Service", modified("Rova Prod Service", declare))
        result = next(r for r in app["results"] if r["rule"] == "mail-app-permission")
        self.assertEqual(result["status"], er.FAIL)
        self.assertIn("declared, not consented", result["detail"])

    def test_full_access_as_app_counts_as_a_mail_permission(self):
        graph = copy.deepcopy(GRAPH)
        graph["resources"]["bbbbbbbb-0000-4000-8000-00000000000b"] = {
            "appId": "00000002-0000-0ff1-ce00-000000000000", "displayName": "Office 365 Exchange Online",
            "appRoles": [{"id": "f1000000-0000-4000-8000-000000000001", "value": "full_access_as_app"}], "oauth2PermissionScopes": []}
        next(a for a in graph["applications"] if a["displayName"] == "Rova Prod Service")["servicePrincipal"]["appRoleAssignments"].append(
            {"resourceId": "bbbbbbbb-0000-4000-8000-00000000000b", "appRoleId": "f1000000-0000-4000-8000-000000000001"})
        self.assertEqual(status(app_report("Rova Prod Service", graph), "mail-app-permission"), er.FAIL)

    def test_sites_selected_passes_and_sites_all_fails(self):
        def selected(app):
            app["servicePrincipal"]["appRoleAssignments"] = [{"resourceId": "aaaaaaaa-0000-4000-8000-00000000000a", "appRoleId": "f0000000-0000-4000-8000-000000000005"}]
        def all_sites(app):
            app["servicePrincipal"]["appRoleAssignments"] = [{"resourceId": "aaaaaaaa-0000-4000-8000-00000000000a", "appRoleId": "f0000000-0000-4000-8000-000000000004"}]
        self.assertEqual(status(app_report("Rova Prod Service", modified("Rova Prod Service", selected)), "sites-scope"), er.PASS)
        self.assertEqual(status(app_report("Rova Prod Service", modified("Rova Prod Service", all_sites)), "sites-scope"), er.FAIL)

    def test_unresolvable_ids_are_reported_not_hidden(self):
        def unknown_role(app):
            app["servicePrincipal"]["appRoleAssignments"] = [{"resourceId": "aaaaaaaa-0000-4000-8000-00000000000a", "appRoleId": "f9999999-0000-4000-8000-000000000009"}]
        app = app_report("Rova Prod Service", modified("Rova Prod Service", unknown_role))
        self.assertTrue(any("unresolved-role" in p for p in app["app_permissions"]))

    def test_an_app_without_a_service_principal_fails_assignment_required(self):
        def drop(app):
            app["servicePrincipal"] = None
        self.assertEqual(status(app_report("Rova Prod", modified("Rova Prod", drop)), "signin-assignment-required"), er.FAIL)

    def test_a_sign_in_app_with_application_permissions_fails(self):
        def grant(app):
            app["servicePrincipal"]["appRoleAssignments"] = [{"resourceId": "aaaaaaaa-0000-4000-8000-00000000000a", "appRoleId": "f0000000-0000-4000-8000-000000000002"}]
        self.assertEqual(status(app_report("Rova Prod", modified("Rova Prod", grant)), "unscoped-app-permission-only-on-service"), er.FAIL)

    def test_blank_and_none_exchange_fields_never_match_each_other(self):
        exchange = copy.deepcopy(EXCHANGE)
        exchange["servicePrincipals"].append({"AppId": None, "ObjectId": "", "DisplayName": "none", "Identity": "None", "Name": None})
        exchange["roleAssignments"].append({"Name": "blank", "Role": "Application Mail.Send", "RoleAssignee": "", "RoleAssigneeName": None, "CustomResourceScope": None})
        exchange["roleAssignments"].append({"Name": "none-text", "Role": "Application Mail.Send", "RoleAssignee": "None", "RoleAssigneeName": "null", "CustomResourceScope": None})
        for app in report(exchange=exchange)["apps"]:
            self.assertNotIn("blank", app["name"])
        unmatched = [a["Name"] for a in report(exchange=exchange)["unmatchedExchangeMailAssignments"]]
        self.assertIn("blank", unmatched)
        self.assertIn("none-text", unmatched)
        self.assertEqual(failing(app_report("Rova Prod Service", exchange=exchange)), set())  # not blamed for the blanks

    def test_exchange_scope_without_a_recipient_filter_fails(self):
        exchange = copy.deepcopy(EXCHANGE)
        for scope in exchange["managementScopes"]:
            scope["RecipientFilter"] = None
        self.assertEqual(status(app_report("Rova Prod Service", exchange=exchange), "service-mail-rbac-scoped"), er.FAIL)

    def test_a_service_app_with_a_delegated_permission_fails(self):
        def add(app):
            app["requiredResourceAccess"] = [{"resourceAppId": "00000003-0000-0000-c000-000000000000",
                                              "resourceAccess": [{"id": "e0000000-0000-4000-8000-000000000005", "type": "Scope"}]}]
        app = app_report("Rova Prod Service", modified("Rova Prod Service", add))
        self.assertEqual(status(app, "service-no-delegated"), er.FAIL)
        self.assertEqual(status(app_report("Rova Prod"), "service-no-delegated"), er.NA)

    def test_external_service_principals_are_graded_and_microsoft_first_party_only_listed(self):
        external = {e["name"]: e for e in report()["externalPrincipals"]}
        self.assertEqual(external["Contoso Mailer"]["kind"], "third-party")
        self.assertEqual({r["rule"] for r in external["Contoso Mailer"]["results"] if r["status"] == er.FAIL}, {"mail-app-permission"})
        self.assertEqual(external["batch-runner-identity"]["kind"], "managed-identity")
        self.assertEqual({r["rule"] for r in external["batch-runner-identity"]["results"] if r["status"] == er.FAIL}, {"sites-scope"})
        first = external["Example First-Party Connector"]
        self.assertEqual((first["kind"], first["results"]), ("microsoft", []))  # shown, not graded
        self.assertEqual(report()["summary"]["externalFailures"], 2)
        md = er.render_markdown(report())
        self.assertIn("## Service principals with no app registration in this tenant", md)
        self.assertIn("### Microsoft first-party (information only, not graded)", md)
        self.assertLess(md.index("Contoso Mailer"), md.index("Microsoft first-party"))
        self.assertIn("Example First-Party Connector", md.split("Microsoft first-party")[1])

    def test_lock_enabled_without_all_properties_passes_with_a_note(self):
        def partial(app):
            app["servicePrincipalLockConfiguration"] = {"isEnabled": True, "allProperties": False}
        app = app_report("Rova Prod", modified("Rova Prod", partial))
        lock = next(r for r in app["results"] if r["rule"] == "lock")
        self.assertEqual(lock["status"], er.PASS)
        self.assertIn("not a failure", lock["detail"])

    def test_the_report_never_contains_a_secret_field(self):
        text = json.dumps(report()) + er.render_markdown(report())
        for forbidden in ["secretText", "hint", "customKeyIdentifier", '"key"']:
            self.assertNotIn(forbidden, text)


class ReportCli(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(HERE / "entra_report.py"), *args], capture_output=True, text=True)

    def test_writes_markdown_and_json_and_exits_1_on_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = self.run_cli("--graph", str(FIXTURES / "graph.fixture.json"), "--exchange", str(FIXTURES / "exchange.fixture.json"),
                                "--out", tmp, "--now", "2026-10-18T00:00:00Z")
            self.assertEqual(done.returncode, 1, done.stderr)
            self.assertIn("21 failing rule(s)", (pathlib.Path(tmp) / "entra-audit-report.md").read_text())
            self.assertEqual(json.loads((pathlib.Path(tmp) / "entra-audit-report.json").read_text())["summary"]["failures"], 21)

    def test_exits_0_when_everything_passes(self):
        graph = copy.deepcopy(GRAPH)
        graph["applications"] = [a for a in graph["applications"] if a["displayName"] in ("Rova Prod", "Rova Prod Service")]
        graph["externalPrincipals"] = []
        exchange = copy.deepcopy(EXCHANGE)
        exchange["roleAssignments"] = [a for a in exchange["roleAssignments"] if a["Name"] == "rova-mail"]
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / "graph.json").write_text(json.dumps(graph))
            (pathlib.Path(tmp) / "exchange.json").write_text(json.dumps(exchange))
            done = self.run_cli(tmp, "--now", "2026-10-18T00:00:00Z")
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_unusable_input_exits_2_with_a_message(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = pathlib.Path(tmp) / "graph.json"
            empty.write_text(json.dumps({"applications": []}))
            done = self.run_cli(tmp)
            self.assertEqual(done.returncode, 2)
            self.assertIn("zero applications", done.stderr)
            empty.write_text(json.dumps({"nope": 1}))
            self.assertEqual(self.run_cli(tmp).returncode, 2)
            empty.write_text("not json")
            self.assertNotEqual(self.run_cli(tmp).returncode, 0)


# ── the collector, against a fake `az` that serves canned Graph responses ────────────────────────────────

FAKE_AZ = r'''#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
log = os.environ["AZ_LOG"]
raw = json.load(open(os.environ["AZ_RAW"]))
mode = os.environ.get("AZ_MODE", "")
if args[:2] == ["account", "show"]:
    print("tester@example.invalid"); print("99999999-0000-4000-8000-000000000009"); sys.exit(0)
if args[0] != "rest":
    open(log, "a").write("UNEXPECTED " + " ".join(args) + "\n"); sys.exit(9)
method = args[args.index("--method") + 1]
url = args[args.index("--url") + 1]
open(log, "a").write(method.upper() + " " + url + "\n")
base = "https://graph.microsoft.com/v1.0"
path = url[len(base):].split("?")[0]
def out(body): print(json.dumps(body)); sys.exit(0)
def fail(text): sys.stderr.write(text + "\n"); sys.exit(1)
NOT_FOUND = "ERROR: Not Found({\"error\":{\"code\":\"Request_ResourceNotFound\",\"message\":\"Resource does not exist.\"}})"
if mode == "forbidden-with-404-in-request-id" and path.endswith("/appRoleAssignments"):
    fail("ERROR: Forbidden({\"error\":{\"code\":\"Authorization_RequestDenied\",\"innerError\":{\"request-id\":\"4040f0c1-0404-4040-8404-404040404040\"}}})")
if mode == "owners-not-found" and path.endswith("/owners"):
    fail(NOT_FOUND)
if mode == "throttle-once":
    marker = os.environ["AZ_LOG"] + ".throttled"
    if not os.path.exists(marker):
        open(marker, "w").write("1")
        fail("ERROR: TooManyRequests({\"error\":{\"code\":\"TooManyRequests\"}})")
if path == "/applications":
    if "skiptoken" in url:
        out({"value": raw["applications"][2:]})
    out({"value": raw["applications"][:2], "@odata.nextLink": base + "/applications?$skiptoken=2"})
m = re.fullmatch(r"/applications/([^/]+)/(owners|federatedIdentityCredentials)", path)
if m:
    out({"value": raw[m.group(2)].get(m.group(1), [])})
m = re.fullmatch(r"/servicePrincipals\(appId='([^']+)'\)", path)
if m:
    for sp in raw["servicePrincipals"]:
        if sp["appId"] == m.group(1):
            out(sp)
    for rid, res in raw["resources"].items():
        if res["appId"] == m.group(1):
            out(res)
    fail(NOT_FOUND)
m = re.fullmatch(r"/servicePrincipals/([^/]+)/(appRoleAssignments|oauth2PermissionGrants|appRoleAssignedTo)", path)
if m:
    out({"value": raw[m.group(2)].get(m.group(1), [])})
m = re.fullmatch(r"/servicePrincipals/([^/]+)", path)
if m and m.group(1) in raw["resources"]:
    res = dict(raw["resources"][m.group(1)])
    if mode == "big-resource":
        res["appRoles"] = res["appRoles"] + [{"id": "r%d" % i, "value": "Role.%d" % i, "displayName": "x", "description": "d" * 600} for i in range(3000)]
    out(res)
if m and m.group(1) in raw["externals"]:
    out(raw["externals"][m.group(1)])
fail("ERROR: unexpected url " + url)
'''


def raw_graph():
    graph_id = "aaaaaaaa-0000-4000-8000-00000000000a"
    graph_app = "00000003-0000-0000-c000-000000000000"
    sp = lambda n, i: {"id": f"3000{i}000-0000-4000-8000-000000000000", "appId": f"2000{i}000-0000-4000-8000-000000000000",
                       "displayName": n, "appRoleAssignmentRequired": True, "accountEnabled": True, "servicePrincipalType": "Application"}
    app = lambda n, i, **kw: {
        "id": f"1000{i}000-0000-4000-8000-000000000000", "appId": f"2000{i}000-0000-4000-8000-000000000000", "displayName": n,
        "signInAudience": "AzureADMyOrg", "notes": "https://example.invalid/repo", "web": {"redirectUris": ["https://a.example.invalid/cb"], "implicitGrantSettings": {}},
        "spa": {"redirectUris": []}, "publicClient": {"redirectUris": []}, "requiredResourceAccess": [],
        "passwordCredentials": [], "keyCredentials": [], "servicePrincipalLockConfiguration": {"isEnabled": True, "allProperties": True}, **kw}
    apps = [
        app("Rova Prod", 1, passwordCredentials=[{"keyId": "p1", "displayName": "web", "startDateTime": "2026-09-01T00:00:00Z",
                                                  "endDateTime": "2027-01-01T00:00:00Z", "hint": "ab~", "secretText": None, "customKeyIdentifier": None}]),
        app("Rova Prod Service", 2, keyCredentials=[{"keyId": "k1", "displayName": "cert", "startDateTime": "2026-08-01T00:00:00Z",
                                                     "endDateTime": "2027-08-01T00:00:00Z", "type": "AsymmetricX509Cert", "usage": "Verify",
                                                     "key": "SECRET-KEY-MATERIAL", "customKeyIdentifier": "THUMBPRINT"}]),
        app("Rova Dev", 3),
    ]
    sps = [sp("Rova Prod", 1), sp("Rova Prod Service", 2)]  # Rova Dev has no service principal: the fake answers 404
    sps[1]["appRoleAssignmentRequired"] = False
    owner = lambda n: {"@odata.type": "#microsoft.graph.user", "id": f"9000000{n}", "displayName": f"Owner {n}", "userPrincipalName": f"o{n}@example.invalid"}
    return {
        "applications": apps,
        "owners": {a["id"]: [owner(1), owner(2)] for a in apps},
        "federatedIdentityCredentials": {apps[1]["id"]: [{"name": "k3s", "issuer": "https://oidc.example.invalid", "subject": "system:serviceaccount:x:y"}]},
        "servicePrincipals": sps,
        "appRoleAssignments": {sps[1]["id"]: [{"resourceId": graph_id, "appRoleId": "f0000000-0000-4000-8000-000000000001", "resourceDisplayName": "Microsoft Graph", "principalId": "x"}]},
        "oauth2PermissionGrants": {sps[0]["id"]: [{"resourceId": graph_id, "consentType": "AllPrincipals", "scope": "openid profile"}]},
        "externals": {
            "ext-third": {"id": "ext-third", "appId": "5000a000-0000-4000-8000-000000000000", "displayName": "Contoso Mailer", "servicePrincipalType": "Application",
                          "appOwnerOrganizationId": "dddddddd-0000-4000-8000-00000000000d", "accountEnabled": True},
            "ext-ms": {"id": "ext-ms", "appId": "5000b000-0000-4000-8000-000000000000", "displayName": "Example First-Party", "servicePrincipalType": "Application",
                       "appOwnerOrganizationId": "f8cdef31-a31e-4b4a-93e4-5f571e91255a", "accountEnabled": True}},
        "appRoleAssignedTo": {graph_id: [
            {"principalId": sps[1]["id"], "principalType": "ServicePrincipal", "resourceId": graph_id, "appRoleId": "f0000000-0000-4000-8000-000000000001"},
            {"principalId": "ext-third", "principalType": "ServicePrincipal", "resourceId": graph_id, "appRoleId": "f0000000-0000-4000-8000-000000000001"},
            {"principalId": "ext-ms", "principalType": "ServicePrincipal", "resourceId": graph_id, "appRoleId": "f0000000-0000-4000-8000-000000000001"},
            {"principalId": "ext-third", "principalType": "ServicePrincipal", "resourceId": graph_id, "appRoleId": "f0000000-0000-4000-8000-000000000001"},
            {"principalId": "a-group", "principalType": "Group", "resourceId": graph_id, "appRoleId": "f0000000-0000-4000-8000-000000000001"}]},
        "resources": {graph_id: {"id": graph_id, "appId": graph_app, "displayName": "Microsoft Graph",
                                 "appRoles": [{"id": "f0000000-0000-4000-8000-000000000001", "value": "Mail.Send", "displayName": "Send mail", "isEnabled": True}],
                                 "oauth2PermissionScopes": [{"id": "e0000000-0000-4000-8000-000000000001", "value": "openid", "adminConsentDisplayName": "x"}]}},
    }


def raw_big():
    """What the fake serves for the Graph service principal in big-resource mode (to assert the size claim)."""
    res = next(iter(raw_graph()["resources"].values()))
    return res["appRoles"] + [{"id": "r%d" % i, "value": "Role.%d" % i, "displayName": "x", "description": "d" * 600} for i in range(3000)]


@unittest.skipUnless(shutil.which("jq") and shutil.which("bash"), "needs bash and jq")
class Collector(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        az = bin_dir / "az"
        az.write_text(FAKE_AZ)
        az.chmod(az.stat().st_mode | stat.S_IEXEC)
        (self.tmp / "raw.json").write_text(json.dumps(raw_graph()))
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", AZ_LOG=str(self.tmp / "az.log"), AZ_RAW=str(self.tmp / "raw.json"), HOME=str(self.tmp))
        self.out = self.tmp / "out"

    def run_script(self, *args, env=None):
        return subprocess.run(["bash", str(HERE / "entra-audit.sh"), *args], capture_output=True, text=True, env=env or self.env, cwd=self.tmp)

    def test_collects_graph_json_and_makes_only_get_requests(self):
        done = self.run_script(str(self.out), "--no-report")
        self.assertEqual(done.returncode, 0, done.stderr)
        log = (self.tmp / "az.log").read_text().splitlines()
        self.assertTrue(log and all(line.startswith("GET https://graph.microsoft.com/v1.0/") for line in log), log)
        graph = json.loads((self.out / "graph.json").read_text())
        names = [a["displayName"] for a in graph["applications"]]
        self.assertEqual(sorted(names), ["Rova Dev", "Rova Prod", "Rova Prod Service"])  # followed the nextLink to the third app
        by_name = {a["displayName"]: a for a in graph["applications"]}
        self.assertIsNone(by_name["Rova Dev"]["servicePrincipal"])  # 404 became null
        self.assertEqual(len(by_name["Rova Prod"]["owners"]), 2)
        self.assertEqual(by_name["Rova Prod"]["owners"][0], {"type": "user", "displayName": "Owner 1", "userPrincipalName": "o1@example.invalid"})
        self.assertEqual(by_name["Rova Prod Service"]["federatedCredentials"], [{"name": "k3s", "issuer": "https://oidc.example.invalid"}])
        self.assertEqual(by_name["Rova Prod Service"]["servicePrincipal"]["appRoleAssignments"][0]["appRoleId"], "f0000000-0000-4000-8000-000000000001")
        resource = next(iter(graph["resources"].values()))
        self.assertEqual(resource["appRoles"], [{"id": "f0000000-0000-4000-8000-000000000001", "value": "Mail.Send", "displayName": "Send mail"}])

    def test_no_secret_material_reaches_the_output(self):
        self.run_script(str(self.out), "--no-report")
        text = (self.out / "graph.json").read_text()
        for forbidden in ["hint", "secretText", "SECRET-KEY-MATERIAL", "THUMBPRINT", "customKeyIdentifier", "system:serviceaccount"]:
            self.assertNotIn(forbidden, text)
        self.assertIn('"keyId":"p1"', text.replace(" ", ""))  # metadata is kept

    def test_end_to_end_report_flags_the_mail_permission_and_exits_1(self):
        done = self.run_script(str(self.out))
        self.assertEqual(done.returncode, 1, done.stderr)
        md = (self.out / "entra-audit-report.md").read_text()
        self.assertIn("Mail.Send (CONSENTED)", md)
        data = json.loads((self.out / "entra-audit-report.json").read_text())
        dev = next(a for a in data["apps"] if a["name"] == "Rova Dev")
        self.assertIn("signin-assignment-required", [r["rule"] for r in dev["results"] if r["status"] == "FAIL"])

    def test_report_only_reuses_collected_files(self):
        self.run_script(str(self.out), "--no-report")
        before = len((self.tmp / "az.log").read_text().splitlines())
        done = self.run_script("--report-only", str(self.out))
        self.assertEqual(done.returncode, 1)
        self.assertEqual(len((self.tmp / "az.log").read_text().splitlines()), before)  # no new request
        self.assertTrue((self.out / "entra-audit-report.md").exists())

    def test_refuses_an_output_directory_inside_a_git_repository(self):
        repo = self.tmp / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        done = self.run_script(str(repo / "out"), "--no-report")
        self.assertEqual(done.returncode, 2)
        self.assertIn("inside a git repository", done.stderr)
        self.assertFalse((repo / "out").exists())

    def run_mode(self, mode, *args):
        env = dict(self.env, AZ_MODE=mode, ENTRA_AUDIT_RETRY_SLEEP="0")
        return self.run_script(str(self.out), "--no-report", *args, env=env)

    def test_a_403_whose_request_id_contains_404_aborts_the_run(self):
        done = self.run_mode("forbidden-with-404-in-request-id")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("GET failed", done.stderr)
        self.assertIn("appRoleAssignments", done.stderr)
        self.assertFalse((self.out / "graph.json").exists())  # no partial result that reads as "nothing consented"

    def test_not_found_is_an_error_everywhere_except_the_service_principal_lookup(self):
        done = self.run_mode("owners-not-found")
        self.assertNotEqual(done.returncode, 0)
        self.assertFalse((self.out / "graph.json").exists())

    def test_throttling_is_retried_and_then_succeeds(self):
        done = self.run_mode("throttle-once")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("retrying in 10s", done.stderr)
        self.assertTrue((self.out / "graph.json").exists())

    def test_a_resource_service_principal_over_one_megabyte_collects(self):
        done = self.run_mode("big-resource")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("Argument list too long", done.stderr)
        resources = json.loads((self.out / "graph.json").read_text())["resources"]
        graph = next(r for r in resources.values() if r["displayName"] == "Microsoft Graph")
        self.assertGreater(len(graph["appRoles"]), 3000)
        self.assertGreater(len(json.dumps(raw_big())), 1_000_000)  # the body really exceeded the old per-argument limits

    def test_service_principals_without_an_app_registration_are_collected(self):
        self.run_script(str(self.out), "--no-report")
        graph = json.loads((self.out / "graph.json").read_text())
        external = {e["displayName"]: e for e in graph["externalPrincipals"]}
        self.assertEqual(sorted(external), ["Contoso Mailer", "Example First-Party"])  # the app's own SP and the Group are not external; duplicates collapse
        self.assertEqual(external["Contoso Mailer"]["appRoleAssignments"][0]["appRoleId"], "f0000000-0000-4000-8000-000000000001")
        done = self.run_script("--report-only", str(self.out))
        md = (self.out / "entra-audit-report.md").read_text()
        self.assertIn("Contoso Mailer | third-party", md)
        self.assertIn("Example First-Party: Microsoft Graph: Mail.Send", md)  # first-party is listed, not graded
        self.assertEqual(done.returncode, 1)

    def test_prints_the_tenant_next_to_the_user(self):
        done = self.run_script(str(self.out), "--no-report")
        self.assertIn("Signed in as: tester@example.invalid (tenant 99999999-0000-4000-8000-000000000009)", done.stderr)

    def test_a_not_yet_existing_directory_inside_a_repository_is_refused(self):
        repo = self.tmp / "repo2"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        target = repo / "a" / "b" / "out"
        done = self.run_script(str(target), "--no-report")
        self.assertEqual(done.returncode, 2)
        self.assertIn("inside a git repository", done.stderr)
        self.assertFalse((repo / "a").exists())
        self.assertFalse(list(repo.rglob("graph.json")))

    def test_report_only_also_refuses_a_directory_inside_a_repository(self):
        repo = self.tmp / "repo3"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "graph.json").write_text("{}")
        self.assertEqual(self.run_script("--report-only", str(repo)).returncode, 2)

    def test_an_old_python_is_refused_with_a_clear_message(self):
        self.run_script(str(self.out), "--no-report")
        old = self.tmp / "oldbin"
        old.mkdir()
        (old / "python3").write_text("#!/bin/sh\n[ \"$1\" = -V ] && { echo 'Python 3.9.6'; exit 0; }\nexit 1\n")
        (old / "python3").chmod(0o755)
        env = dict(self.env, PATH=f"{old}:{os.environ['PATH']}")
        done = self.run_script("--report-only", str(self.out), env=env)
        self.assertEqual(done.returncode, 2)
        self.assertIn("Python 3.10+ is needed", done.stderr)
        self.assertIn("3.9.6", done.stderr)

    def test_files_are_owner_only(self):
        self.run_script(str(self.out), "--no-report")
        self.assertEqual(stat.S_IMODE((self.out / "graph.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o700)

    def test_not_signed_in_is_a_clear_error(self):
        bin_dir = self.tmp / "bin2"
        bin_dir.mkdir()
        (bin_dir / "az").write_text("#!/bin/sh\nexit 1\n")
        (bin_dir / "az").chmod(0o755)
        env = dict(self.env, PATH=f"{bin_dir}:{os.environ['PATH']}")
        done = self.run_script(str(self.out), env=env)
        self.assertEqual(done.returncode, 2)
        self.assertIn("az login --tenant", done.stderr)

    def test_an_empty_tenant_is_an_error_not_an_empty_report(self):
        raw = raw_graph()
        raw["applications"] = []
        (self.tmp / "raw.json").write_text(json.dumps(raw))
        done = self.run_script(str(self.out), "--no-report")
        self.assertEqual(done.returncode, 2)
        self.assertIn("no applications", done.stderr)

    def test_an_unreadable_lock_property_is_noted_in_the_report(self):
        raw = raw_graph()
        for a in raw["applications"]:
            a.pop("servicePrincipalLockConfiguration")
        (self.tmp / "raw.json").write_text(json.dumps(raw))
        self.run_script(str(self.out))
        self.assertIn("servicePrincipalLockConfiguration", (self.out / "entra-audit-report.md").read_text().split("## Overview")[0])


# ── the Exchange script, with stand-ins for the Get-* cmdlets ────────────────────────────────────────────

@unittest.skipUnless(shutil.which("pwsh"), "needs pwsh")
class ExchangeScript(unittest.TestCase):
    ASSIGNMENTS = """
  [pscustomobject]@{Name='x';Role='Application Mail.Send';RoleAssignee='o1';RoleAssigneeName='o1';RoleAssigneeType='ServicePrincipal';CustomResourceScope=$null;Enabled=$true}
  [pscustomobject]@{Name='y';Role='Application Mail.Send';RoleAssignee='o2';RoleAssigneeName='o2';RoleAssigneeType='ServicePrincipal';CustomResourceScope='sc1';Enabled=$true}
"""
    COMMON = """
function Get-ServicePrincipal { [pscustomobject]@{AppId='a1';ObjectId='o1';DisplayName='Rova Prod Service';Identity='o1';Name='rova'} }
function Get-ManagementScope { [pscustomobject]@{Name='sc1';ScopeRestrictionType='RecipientScope';RecipientFilter="PrimarySmtpAddress -eq 'a@example.invalid'";Exclusive=$false} }
"""
    WITH_TYPE = COMMON + "function Get-ManagementRoleAssignment { param($RoleAssigneeType) " + ASSIGNMENTS + " }\n"
    # An Exchange build that rejects -RoleAssigneeType ServicePrincipal, and lists user assignments too
    WITHOUT_TYPE = COMMON + "function Get-ManagementRoleAssignment { [CmdletBinding()] param() " + ASSIGNMENTS + \
        "  [pscustomobject]@{Name='u';Role='Application Mail.Send';RoleAssignee='someone';RoleAssigneeName='someone';RoleAssigneeType='User';CustomResourceScope=$null}\n }\n"

    def run_ps(self, standins, out_dir, with_graph=True):
        out = pathlib.Path(out_dir)
        if with_graph:
            out.mkdir(parents=True, exist_ok=True)
            (out / "graph.json").write_text("{}")
        command = standins + f"& '{HERE / 'exchange-rbac-audit.ps1'}' -NoConnect -OutDir '{out_dir}'; exit $LASTEXITCODE"
        return subprocess.run(["pwsh", "-NoProfile", "-Command", command], capture_output=True, text=True)

    def test_writes_exchange_json_and_flags_the_unscoped_assignment(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = self.run_ps(self.WITH_TYPE, tmp)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)  # 1 = an unscoped assignment exists
            self.assertIn("FAIL  Rova Prod Service (o1): Application Mail.Send  has NO custom resource scope", done.stdout)
            self.assertIn("ok    o2: Application Mail.Send  scope 'sc1' = PrimarySmtpAddress -eq 'a@example.invalid'", done.stdout)
            model = json.loads((pathlib.Path(tmp) / "exchange.json").read_text())
            self.assertEqual([a["CustomResourceScope"] for a in model["roleAssignments"]], [None, "sc1"])
            self.assertEqual(model["managementScopes"][0]["RecipientFilter"], "PrimarySmtpAddress -eq 'a@example.invalid'")
            self.assertEqual(stat.S_IMODE((pathlib.Path(tmp) / "exchange.json").stat().st_mode), 0o600)

    def test_falls_back_to_client_side_filtering_when_the_assignee_type_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = self.run_ps(self.WITHOUT_TYPE, tmp)
            self.assertIn("filtering client-side", done.stdout + done.stderr)
            model = json.loads((pathlib.Path(tmp) / "exchange.json").read_text())
            self.assertEqual([a["Name"] for a in model["roleAssignments"]], ["x", "y"])  # the User assignment was filtered out

    def test_requires_graph_json_from_the_same_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = self.run_ps(self.WITH_TYPE, tmp, with_graph=False)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn("Run entra-audit.sh first", done.stdout + done.stderr)
            self.assertFalse((pathlib.Path(tmp) / "exchange.json").exists())

    def test_refuses_a_directory_inside_a_git_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "init", "-q", tmp], check=True)
            done = self.run_ps(self.WITH_TYPE, pathlib.Path(tmp) / "new" / "dir", with_graph=False)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn("inside a git repository", done.stdout + done.stderr)
            self.assertFalse((pathlib.Path(tmp) / "new").exists())

    def test_its_output_feeds_the_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.run_ps(self.WITH_TYPE, tmp)
            exchange = json.loads((pathlib.Path(tmp) / "exchange.json").read_text())
            graph = copy.deepcopy(GRAPH)
            service = next(a for a in graph["applications"] if a["displayName"] == "Rova Prod Service")
            service["servicePrincipal"]["id"] = "o1"
            self.assertEqual(status(app_report("Rova Prod Service", graph, exchange), "service-mail-rbac-scoped"), er.FAIL)


# ── the read-only guard ──────────────────────────────────────────────────────────────────────────────────

class ReadOnlyGuard(unittest.TestCase):
    def guard(self, name, content):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / name
            path.write_text(content)
            return subprocess.run(["bash", str(HERE / "check-readonly.sh"), str(path)], capture_output=True, text=True)

    def test_the_real_scripts_pass(self):
        done = subprocess.run(["bash", str(HERE / "check-readonly.sh")], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_shell_changes_are_rejected(self):
        bad = {
            "post": 'az rest --method post --url "$u"',
            "delete": 'az rest --method DELETE --url "$u"',
            "patch-equals": 'az rest --method=patch --url "$u"',
            "no method": 'az rest --url "$u"',
            "second call site": 'az rest --method get --url a\naz rest --method get --url b',
            "body": 'az rest --method get --url a --body {}',
            "curl": 'curl -s https://example.invalid',
            "az ad": 'az ad app delete --id x',
            "az role": 'az role assignment create',
            "short method": 'az rest -m post --url "$u"',
            "short body": 'az rest --method get --url "$u" -b {}',
            "login hint in a message is fine but a real login is not": 'az login --tenant x',
        }
        for label, line in bad.items():
            done = self.guard("x.sh", line + "\n")
            self.assertEqual(done.returncode, 1, label)

    def test_shell_reads_and_comments_are_accepted(self):
        ok = '# az rest --method post is only a comment\naz account show --query user.name -o tsv\naz rest --method get --url "$u" --output json\ndie "run \'az login\' first"\n'
        self.assertEqual(self.guard("x.sh", ok).returncode, 0)

    def test_powershell_changes_are_rejected(self):
        for cmd in ["[System.IO.File]::Delete('x')", "[IO.File]::WriteAllText('x','y')", "$f.Delete()", "cmd /c del x", "New-ServicePrincipal", "Set-Mailbox -X", "Remove-ManagementRoleAssignment", "Add-MailboxPermission", "Invoke-RestMethod http://x",
                    "New-ManagementScope", "Update-Foo", "Install-Module X", "Enable-Foo", "Send-MailMessage"]:
            self.assertEqual(self.guard("x.ps1", cmd + "\n").returncode, 1, cmd)

    def test_powershell_reads_comments_and_block_comments_are_accepted(self):
        ok = "<#\n New-ServicePrincipal is only documentation here\n#>\n# Set-Mailbox also\nSet-StrictMode -Version Latest\nGet-ServicePrincipal | Out-File x\nWrite-Host hi\nConnect-ExchangeOnline\n"
        self.assertEqual(self.guard("x.ps1", ok).returncode, 0)


if __name__ == "__main__":
    unittest.main()
