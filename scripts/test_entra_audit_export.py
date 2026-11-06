"""Tests for entra_audit_export.py. Standard library only: `python3 -m unittest scripts/test_entra_audit_export.py`."""

from __future__ import annotations

import datetime as dt
import gzip
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import entra_audit_export as ex  # noqa: E402

NOW = dt.datetime(2026, 11, 6, 12, 0, 0, tzinfo=dt.timezone.utc)


def page(values: list[dict], next_link: str | None = None) -> dict:
    body = {"value": values}
    if next_link:
        body["@odata.nextLink"] = next_link
    return body


class Collect(unittest.TestCase):
    def test_pages_and_dedupes_by_id(self):
        calls: list[str] = []

        def fetch(url, token):
            calls.append(url)
            if len(calls) == 1:
                return page([{"id": "a"}, {"id": "b"}], "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$skiptoken=abc")
            return page([{"id": "b"}, {"id": "c"}])

        records = ex.collect("2026-11-05T00:00:00Z", "token", fetch=fetch)
        self.assertEqual([r["id"] for r in records], ["a", "b", "c"])
        self.assertEqual(len(calls), 2)

    def test_records_without_id_are_skipped(self):
        def fetch(url, token):
            return page([{"id": "a"}, {"activityDateTime": "x"}, {"id": ""}])

        self.assertEqual([r["id"] for r in ex.collect("2026-11-05T00:00:00Z", "t", fetch=fetch)], ["a"])

    def test_filter_carries_the_since_timestamp(self):
        seen = {}

        def fetch(url, token):
            seen["url"] = url
            return page([])

        ex.collect("2026-11-05T00:00:00Z", "t", fetch=fetch)
        self.assertIn("auditLogs/directoryAudits", seen["url"])
        self.assertIn("%24filter=activityDateTime+ge+2026-11-05T00%3A00%3A00Z", seen["url"])
        self.assertIn("%24top=1000", seen["url"])


class BlobNaming(unittest.TestCase):
    def test_path_is_date_partitioned_and_unique_per_run(self):
        self.assertEqual(ex.blob_path(NOW), "2026/11/06/audit-20261106T120000Z.jsonl.gz")
        later = NOW + dt.timedelta(hours=1)
        self.assertNotEqual(ex.blob_path(NOW), ex.blob_path(later))


class WriteFile(unittest.TestCase):
    def test_gzip_jsonl_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "out.jsonl.gz"
            ex.write_gzip_jsonl([{"id": "a", "k": 1}, {"id": "b", "k": 2}], path)
            with gzip.open(path, "rt", encoding="utf-8") as handle:
                lines = [json.loads(line) for line in handle if line.strip()]
        self.assertEqual(lines, [{"id": "a", "k": 1}, {"id": "b", "k": 2}])


class Main(unittest.TestCase):
    def test_empty_window_exits_zero_without_upload(self):
        with mock.patch.object(ex, "graph_token", return_value="t"), \
             mock.patch.object(ex, "collect", return_value=[]), \
             mock.patch.object(ex, "upload") as upload:
            self.assertEqual(ex.main(["--hours", "24"]), 0)
        upload.assert_not_called()

    def test_dry_run_writes_without_upload(self):
        records = [{"id": "a"}]
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(ex, "graph_token", return_value="t"), \
             mock.patch.object(ex, "collect", return_value=records), \
             mock.patch.object(ex, "upload") as upload:
            code = ex.main(["--hours", "24", "--dry-run", "--out-dir", tmp])
            files = list(pathlib.Path(tmp).iterdir())
        self.assertEqual(code, 0)
        upload.assert_not_called()
        self.assertEqual(len(files), 1)

    def test_graph_failure_exits_non_zero(self):
        with mock.patch.object(ex, "graph_token", side_effect=ex.ExportError("Graph directoryAudits returned HTTP 403")):
            self.assertEqual(ex.main(["--hours", "24"]), 1)

    def test_rejects_windows_longer_than_retention(self):
        self.assertEqual(ex.main(["--hours", "200"]), 2)


class GraphOnly(unittest.TestCase):
    def test_accepts_graph(self):
        ex.require_graph_url("https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$top=1")

    def test_rejects_another_host(self):
        with self.assertRaises(ex.ExportError):
            ex.require_graph_url("https://evil.example/collect")

    def test_rejects_userinfo_spoof(self):
        # urlsplit reads the host here as evil.example, not graph.microsoft.com.
        with self.assertRaises(ex.ExportError):
            ex.require_graph_url("https://graph.microsoft.com@evil.example/collect")

    def test_rejects_plain_http_and_subdomains(self):
        for url in ("http://graph.microsoft.com/v1.0/x",
                    "https://graph.microsoft.com.evil.example/x",
                    "https://evilgraph.microsoft.com/x"):
            with self.subTest(url=url), self.assertRaises(ex.ExportError):
                ex.require_graph_url(url)

    def test_collect_refuses_a_foreign_next_link(self):
        def fetch(url, token):
            return {"value": [{"id": "a"}], "@odata.nextLink": "https://evil.example/next"}

        with self.assertRaises(ex.ExportError):
            ex.collect("2026-11-05T00:00:00Z", "t", fetch=fetch)

    def test_fetch_json_validates_before_requesting(self):
        with mock.patch.object(ex.urllib.request, "urlopen") as urlopen, self.assertRaises(ex.ExportError):
            ex.fetch_json("https://evil.example/collect", "t")
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
