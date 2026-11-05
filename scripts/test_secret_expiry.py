"""Tests for secret_expiry.py. Standard library only: `python3 -m unittest scripts/test_secret_expiry.py`."""

from __future__ import annotations

import datetime as dt
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import secret_expiry as se  # noqa: E402

NOW = dt.datetime(2026, 11, 4, tzinfo=dt.timezone.utc)


def at(days: int) -> str:
    return (NOW + dt.timedelta(days=days)).isoformat().replace("+00:00", "Z")


class Timestamps(unittest.TestCase):
    def test_iso_with_z(self):
        self.assertEqual(se.parse_timestamp("2027-01-30T00:00:00Z"), dt.datetime(2027, 1, 30, tzinfo=dt.timezone.utc))

    def test_epoch_seconds(self):
        self.assertEqual(se.parse_timestamp(1790000000), dt.datetime.fromtimestamp(1790000000, dt.timezone.utc))

    def test_graph_no_expiry_sentinel_is_missing(self):
        self.assertIsNone(se.parse_timestamp("0001-01-01T00:00:00Z"))

    def test_garbage_is_missing(self):
        self.assertIsNone(se.parse_timestamp("not a date"))


class KeyVault(unittest.TestCase):
    def run_one(self, vault, name, exp):
        secret = {"name": name, "attributes": {} if exp is None else {"exp": exp}}
        return se.evaluate_key_vault([secret], vault, NOW)[0]

    def test_prod_missing_expiry_fails(self):
        finding = self.run_one("kv-qnsc-prod", "rova-prod-app", None)
        self.assertEqual(finding.status, se.FAIL)
        self.assertIn("no expiry", finding.detail)

    def test_platform_missing_expiry_fails(self):
        self.assertEqual(self.run_one("kv-qnsc-platform", "platform-argocd-x", None).status, se.FAIL)

    def test_dev_missing_expiry_warns(self):
        self.assertEqual(self.run_one("kv-qnsc-dev", "kb-dev-secret-key", None).status, se.WARN)

    def test_access_aud_without_expiry_is_ok(self):
        self.assertEqual(self.run_one("kv-qnsc-prod", "rova-prod-mcp-access-aud", None).status, se.OK)

    def test_expiring_in_29_days_warns(self):
        finding = self.run_one("kv-qnsc-prod", "rova-prod-app", int((NOW + dt.timedelta(days=29)).timestamp()))
        self.assertEqual(finding.status, se.WARN)
        self.assertEqual(finding.days, 29)

    def test_31_days_is_ok(self):
        finding = self.run_one("kv-qnsc-prod", "rova-prod-app", int((NOW + dt.timedelta(days=31)).timestamp()))
        self.assertEqual(finding.status, se.OK)

    def test_expired_fails(self):
        finding = self.run_one("kv-qnsc-prod", "rova-prod-app", int((NOW - dt.timedelta(days=2)).timestamp()))
        self.assertEqual(finding.status, se.FAIL)
        self.assertIn("expired", finding.detail)


class Entra(unittest.TestCase):
    def test_secret_expiring_soon_warns(self):
        apps = [{"displayName": "Rova Dev", "passwordCredentials": [{"displayName": "s1", "endDateTime": at(10)}]}]
        finding = se.evaluate_entra(apps, NOW)[0]
        self.assertEqual(finding.status, se.WARN)
        self.assertEqual(finding.kind, "client secret")

    def test_certificate_without_end_fails(self):
        apps = [{"displayName": "Rova Prod Service", "keyCredentials": [{"displayName": "c1"}]}]
        finding = se.evaluate_entra(apps, NOW)[0]
        self.assertEqual(finding.status, se.FAIL)
        self.assertIn("readable end date", finding.detail)

    def test_year_one_end_fails_as_unreadable(self):
        apps = [{"displayName": "X", "passwordCredentials": [{"endDateTime": "0001-01-01T00:00:00Z"}]}]
        self.assertEqual(se.evaluate_entra(apps, NOW)[0].status, se.FAIL)


class EntraCollection(unittest.TestCase):
    def test_an_empty_app_list_is_a_collection_error(self):
        with self.assertRaises(se.CollectionError):
            se.validate_entra_apps([])

    def test_apps_without_credentials_are_a_collection_error(self):
        with self.assertRaises(se.CollectionError):
            se.validate_entra_apps([{"displayName": "X"}])

    def test_credentials_are_counted(self):
        apps = [{"passwordCredentials": [{"endDateTime": at(10)}], "keyCredentials": [{}]}]
        self.assertEqual(se.validate_entra_apps(apps), 2)


class Report(unittest.TestCase):
    def test_only_notable_rows_and_counts(self):
        findings = [
            se.classify(source="kv-qnsc-prod", name="missing", kind="Key Vault secret", expires=None, now=NOW, required=True),
            se.classify(source="kv-qnsc-prod", name="fine", kind="Key Vault secret", expires=NOW + dt.timedelta(days=100), now=NOW, required=True),
        ]
        report = se.render_markdown(findings, NOW, ["kv-qnsc-prod"], 0)
        self.assertIn("**1 FAIL, 0 WARN, 1 OK.**", report)
        self.assertIn("| FAIL | kv-qnsc-prod | missing |", report)
        self.assertNotIn("| OK |", report)

    def test_clean_report_says_so(self):
        findings = [se.classify(source="kv-qnsc-prod", name="fine", kind="Key Vault secret", expires=NOW + dt.timedelta(days=100), now=NOW, required=True)]
        self.assertIn("No credential expires within 30 days", se.render_markdown(findings, NOW, ["kv-qnsc-prod"], 0))


if __name__ == "__main__":
    unittest.main()
