"""Tests for alerting_health.py. Standard library only: `python3 -m unittest scripts/test_alerting_health.py`."""

from __future__ import annotations

import io
import json
import os
import pathlib
import sys
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import alerting_health as ah  # noqa: E402


class Response:
    def __init__(self, status, body=b""):
        self.status = status
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return self._body


def json_response(payload):
    return Response(200, json.dumps(payload).encode())


def http_error(code):
    return urllib.error.HTTPError("https://x", code, "err", {}, io.BytesIO(b""))


class GrafanaToken(unittest.TestCase):
    def run_check(self, side_effect, token="t"):
        env = {"GRAFANA_ALERTS_TOKEN": token} if token else {}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            ah.urllib.request, "urlopen", side_effect=side_effect
        ):
            return ah.check_grafana()

    def test_an_accepted_token_is_clean(self):
        self.assertEqual(self.run_check(lambda *a, **k: Response(200)), ([], []))

    def test_a_rejected_token_fails(self):
        def boom(*a, **k):
            raise http_error(401)

        fails, _ = self.run_check(boom)
        self.assertEqual(len(fails), 1)
        self.assertIn("rejected", fails[0][1])

    def test_a_missing_token_is_skipped_not_clean(self):
        with self.assertRaises(ah.Skipped):
            self.run_check(lambda *a, **k: Response(200), token="")


class AlertRulesHaveData(unittest.TestCase):
    rule = {
        "isPaused": False,
        "ruleGroup": "rova (prod)",
        "title": "rova-prod-http-5xx-rate",
        "data": [
            {
                "datasourceUid": "prom-uid",
                "model": {
                    "expr": "sum(rate(http_server_requests_total[5m]))",
                    "datasource": {"type": "prometheus", "uid": "prom-uid"},
                },
            },
            {"datasourceUid": "__expr__", "model": {"type": "threshold"}},
        ],
    }

    def run_check(self, rules, result):
        def fake_urlopen(request, timeout=30):
            if "/api/v1/provisioning/alert-rules" in request.full_url:
                return json_response(rules)
            return json_response({"data": {"result": result}})

        with mock.patch.dict(os.environ, {"GRAFANA_ALERTS_TOKEN": "t"}, clear=True), mock.patch.object(
            ah.urllib.request, "urlopen", side_effect=fake_urlopen
        ):
            return ah.check_alert_rules_have_data()

    def test_a_rule_with_data_is_clean(self):
        self.assertEqual(self.run_check([self.rule], [{"metric": {}}]), ([], []))

    def test_a_rule_with_no_data_in_seven_days_warns(self):
        _, warns = self.run_check([self.rule], [])
        self.assertEqual(len(warns), 1)
        self.assertIn("no data in 7 days", warns[0][1])

    def test_a_loki_rule_is_skipped(self):
        loki = {
            "isPaused": False,
            "ruleGroup": "security",
            "title": "security-control-failed-open-production",
            "data": [
                {
                    "datasourceUid": "loki-uid",
                    "model": {"expr": "{service_namespace=~\".+-prod\"}", "datasource": {"type": "loki"}},
                }
            ],
        }
        self.assertEqual(self.run_check([loki], []), ([], []))

    def test_a_missing_token_is_skipped(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ah.Skipped):
                ah.check_alert_rules_have_data()


if __name__ == "__main__":
    unittest.main()
