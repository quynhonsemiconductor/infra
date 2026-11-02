"""Tests for alerting_health.py. Standard library only: `python3 -m unittest scripts/test_alerting_health.py`."""

from __future__ import annotations

import io
import os
import pathlib
import sys
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import alerting_health as ah  # noqa: E402


class Response:
    def __init__(self, status):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


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


if __name__ == "__main__":
    unittest.main()
