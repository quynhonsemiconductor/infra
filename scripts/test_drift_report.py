"""Tests for drift_report.py:  python3 scripts/test_drift_report.py   (stdlib only)"""
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def drift(address, rtype, actions):
    return {"address": address, "type": rtype, "change": {"actions": actions}}


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

    def test_a_dns_or_identity_change_matters(self):
        for rtype in ("cloudflare_record", "aws_acm_certificate", "aws_sesv2_email_identity", "cloudflare_r2_custom_domain"):
            with self.subTest(rtype=rtype):
                self.assertEqual(run([drift("x.y", rtype, ["update"])])[0], 2)

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
