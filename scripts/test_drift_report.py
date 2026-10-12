"""Tests for drift_report.py:  python3 scripts/test_drift_report.py   (stdlib only)"""
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def drift(address, rtype, actions, before=None, after=None):
    change = {"actions": actions}
    if before is not None or after is not None:
        change.update(before=before, after=after)
    return {"address": address, "type": rtype, "change": change}


def run(doc=None, raw=None):
    text = raw if raw is not None else json.dumps({"format_version": "1.2", "resource_drift": doc})
    r = subprocess.run([sys.executable, os.path.join(HERE, "drift_report.py")], input=text, capture_output=True, text=True)
    return r.returncode, r.stdout


class DriftReport(unittest.TestCase):
    def test_no_drift(self):
        self.assertEqual(run([])[0], 0)
        self.assertEqual(run(None)[0], 0)

    def test_the_noise_seen_every_night_is_informational(self):
        # what the 2026-10-12 runs reported for runtime-dev, runtime-prod and security-baseline
        code, out = run([drift("module.shared_cache[0].aws_elasticache_replication_group.this[0]", "aws_elasticache_replication_group", ["update"]),
                         drift("module.network.aws_security_group.rds", "aws_security_group", ["update"]),
                         drift("aws_sns_topic.security_alerts", "aws_sns_topic", ["update"]),
                         drift("aws_ce_anomaly_subscription.alerts[0]", "aws_ce_anomaly_subscription", ["update"])])
        self.assertEqual(code, 3)
        self.assertIn("informational", out)

    def test_a_resource_deleted_outside_tofu_matters_whatever_its_type(self):
        code, out = run([drift("aws_sns_topic.security_alerts", "aws_sns_topic", ["delete"])])
        self.assertEqual(code, 2)
        self.assertIn("DELETED outside OpenTofu", out)

    def test_a_dns_or_identity_change_matters_when_we_cannot_tell_what_changed(self):
        # no before/after in the plan: fail closed
        for rtype in ("cloudflare_record", "aws_acm_certificate", "aws_sesv2_email_identity", "cloudflare_r2_custom_domain"):
            with self.subTest(rtype=rtype):
                self.assertEqual(run([drift("x.y", rtype, ["update"])])[0], 2)

    def test_a_real_attribute_change_on_a_dns_record_matters(self):
        code, out = run([drift("cloudflare_record.landing", "cloudflare_record", ["update"],
                               {"content": "a.pages.dev", "tags": None}, {"content": "evil.example", "tags": []})])
        self.assertEqual(code, 2)
        self.assertIn("content", out)
        self.assertNotIn("tags", out.split("content")[1][:3])

    def test_the_2026_10_13_noise_on_dns_records_and_r2_domain_is_informational(self):
        # what run 38282001351 reported for edge (tags null -> []) and storage-dev/prod (status pending -> active)
        code, out = run([
            drift("cloudflare_record.ses_dkim[0]", "cloudflare_record", ["update"], {"name": "k", "tags": None}, {"name": "k", "tags": []}),
            drift("module.r.cloudflare_r2_custom_domain.this[0]", "cloudflare_r2_custom_domain", ["update"],
                  {"domain": "d", "status": {"ownership": "pending", "ssl": "initializing"}},
                  {"domain": "d", "status": {"ownership": "active", "ssl": "active"}})])
        self.assertEqual(code, 3, out)

    def test_computed_attributes_are_only_ignored_for_cloudflare(self):
        # an ACM certificate's status really matters
        code, _ = run([drift("aws_acm_certificate.w", "aws_acm_certificate", ["update"], {"status": "ISSUED"}, {"status": "EXPIRED"})])
        self.assertEqual(code, 2)
        code, _ = run([drift("cloudflare_record.a", "cloudflare_record", ["update"], {"modified_on": "1"}, {"modified_on": "2"})])
        self.assertEqual(code, 3)

    def test_significant_wins_over_informational(self):
        code, _ = run([drift("a.b", "aws_sns_topic", ["update"]), drift("cloudflare_record.c", "cloudflare_record", ["update"])])
        self.assertEqual(code, 2)

    def test_noop_entries_are_ignored(self):
        self.assertEqual(run([drift("a.b", "aws_sns_topic", ["no-op"]), drift("c.d", "aws_sns_topic", [])])[0], 0)

    def test_not_a_plan_fails_closed(self):
        for raw in ("", "null", "{}", "[]", "oops", '{"format_version": "1.2", "resour'):
            with self.subTest(raw=raw):
                self.assertEqual(run(raw=raw)[0], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
