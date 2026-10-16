"""Tests for alerting_health.py. Standard library only: `python3 -m unittest scripts/test_alerting_health.py`.

The AWS CLI is replaced by a fake `aws()`, so nothing here needs credentials.
"""

from __future__ import annotations

import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import alerting_health as ah  # noqa: E402

TOPIC = "arn:aws:sns:ap-southeast-1:111111111111:qnsc-security-alerts"
CONFIRMED = "arn:aws:sns:ap-southeast-1:111111111111:qnsc-security-alerts:1234"


def fake_aws(rules, subscriptions=None):
    def aws(*args, region=None):
        if args[:2] == ("events", "list-rules"):
            return {"Rules": rules}
        if args[:2] == ("events", "list-targets-by-rule"):
            return {"Targets": [{"Arn": TOPIC}]}
        if args[:2] == ("sns", "list-subscriptions-by-topic"):
            return {"Subscriptions": subscriptions if subscriptions is not None else [{"SubscriptionArn": CONFIRMED}]}
        raise AssertionError(f"unexpected call {args}")

    return aws


class EventBridgeRuleState(unittest.TestCase):
    def check(self, state, **kwargs):
        with mock.patch.object(ah, "aws", fake_aws([{"Name": "r", "State": state}], **kwargs)):
            return ah.check_eventbridge_delivery()

    def test_enabled_rule_with_a_subscriber_is_clean(self):
        self.assertEqual(self.check("ENABLED"), ([], []))

    def test_the_breakglass_rule_state_is_enabled_not_disabled(self):
        """`qnsc-prod-breakglass-assumed` is ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS: it was reported DISABLED."""
        self.assertEqual(self.check("ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"), ([], []))

    def test_a_disabled_rule_is_still_a_failure(self):
        fails, _ = self.check("DISABLED")
        self.assertEqual(len(fails), 1)
        self.assertIn("DISABLED", fails[0][1])

    def test_the_wide_state_does_not_skip_the_subscriber_check(self):
        fails, _ = self.check("ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS", subscriptions=[])
        self.assertEqual(len(fails), 1)
        self.assertIn("no subscriptions at all", fails[0][1])


if __name__ == "__main__":
    unittest.main()
