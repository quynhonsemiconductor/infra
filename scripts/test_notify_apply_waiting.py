"""Tests for notify_apply_waiting.py. Standard library only:
`python3 -m unittest scripts/test_notify_apply_waiting.py`.

The fixture mirrors the Actions jobs API shape for an infra-apply run: one stack at
the environment gate (`waiting`), one queued behind a running dependency, one already
applied, and jobs that are not apply jobs at all. The dry-run test proves the exact
Teams request body from that fixture without a webhook.
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import notify_apply_waiting as nw  # noqa: E402

RUN_URL = "https://github.com/quynhonsemiconductor/infra/actions/runs/41793269470"
COMMIT = "feat(identity): add the OpsHub prod sign-in and service apps (#337)"

JOBS = {
    "total_count": 5,
    "jobs": [
        {"name": "Detect changed stacks", "status": "completed", "conclusion": "success"},
        {"name": "Plan edge", "status": "completed", "conclusion": "success"},
        {"name": "Apply edge", "status": "waiting", "conclusion": None},
        {"name": "Apply onprem", "status": "queued", "conclusion": None},
        {"name": "Apply storage-dev", "status": "completed", "conclusion": "success"},
    ],
}


def fixture_file(content):
    handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    with handle:
        json.dump(content, handle)
    return handle.name


class StackNames(unittest.TestCase):
    def test_only_apply_jobs_map_to_stacks(self):
        self.assertEqual(nw.stack_of_job("Apply onprem"), "onprem")
        self.assertEqual(nw.stack_of_job("Apply observability-alerting"), "observability-alerting")
        self.assertIsNone(nw.stack_of_job("Plan onprem"))
        self.assertIsNone(nw.stack_of_job("Plan summary"))
        self.assertIsNone(nw.stack_of_job("Apply "))

    def test_expected_accepts_the_gate_json_and_a_comma_list(self):
        self.assertEqual(nw.parse_expected('["edge", "onprem"]'), ["edge", "onprem"])
        self.assertEqual(nw.parse_expected("edge, onprem"), ["edge", "onprem"])
        self.assertEqual(nw.parse_expected("[]"), [])
        self.assertEqual(nw.parse_expected(""), [])


class Selection(unittest.TestCase):
    def test_only_the_stack_at_the_gate_is_announced(self):
        self.assertEqual(nw.waiting_stacks(JOBS["jobs"], ["edge", "onprem"]), ["edge"])
        self.assertEqual(nw.waiting_stacks(JOBS["jobs"], ["onprem"]), [])
        self.assertEqual(nw.finished_stacks(JOBS["jobs"]), {"storage-dev"})


class CardShape(unittest.TestCase):
    def test_the_card_names_the_stack_the_commit_and_the_run(self):
        message = nw.build_message("edge", COMMIT, RUN_URL)
        self.assertEqual(message["type"], "message")
        attachment = message["attachments"][0]
        self.assertEqual(attachment["contentType"], "application/vnd.microsoft.card.adaptive")
        self.assertIsNone(attachment["contentUrl"])

        card = attachment["content"]
        self.assertEqual(card["type"], "AdaptiveCard")
        self.assertEqual(card["version"], "1.4")
        self.assertEqual(
            card["$schema"], "http://adaptivecards.io/schemas/adaptive-card.json"
        )

        texts = [block["text"] for block in card["body"]]
        self.assertIn("Infra apply waiting for approval: edge", texts)
        self.assertIn("Stack: **edge**", texts)
        self.assertIn(f"Commit: {COMMIT}", texts)

        self.assertEqual(
            card["actions"],
            [{"type": "Action.OpenUrl", "title": "Review and approve", "url": RUN_URL}],
        )

    def test_every_body_block_wraps(self):
        card = nw.build_card("onprem", COMMIT, RUN_URL)
        for block in card["body"]:
            self.assertIs(block["wrap"], True)


class DryRun(unittest.TestCase):
    def run_dry(self, expected, jobs):
        path = fixture_file(jobs)
        out = io.StringIO()
        with mock.patch.object(nw.urllib.request, "urlopen", side_effect=AssertionError("no request in a dry run")), \
                contextlib.redirect_stdout(out):
            code = nw.main(
                ["--dry-run", "--jobs", path, "--expected", expected,
                 "--commit-title", COMMIT, "--run-url", RUN_URL]
            )
        return code, out.getvalue()

    def test_dry_run_prints_the_waiting_card_and_makes_no_request(self):
        code, stdout = self.run_dry('["edge","onprem"]', JOBS)
        self.assertEqual(code, 0)
        messages = json.loads(stdout)
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0], nw.build_message("edge", COMMIT, RUN_URL))

    def test_dry_run_is_empty_when_nothing_waits(self):
        code, stdout = self.run_dry('["storage-dev"]', JOBS)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout), [])


class Watch(unittest.TestCase):
    def test_one_card_per_stack_then_exit(self):
        polls = [
            JOBS["jobs"],
            [
                {"name": "Apply edge", "status": "completed", "conclusion": "success"},
                {"name": "Apply onprem", "status": "waiting", "conclusion": None},
            ],
            [
                {"name": "Apply edge", "status": "completed", "conclusion": "success"},
                {"name": "Apply onprem", "status": "completed", "conclusion": "success"},
            ],
        ]
        sent = []

        def fetch():
            return polls.pop(0)

        announced = nw.watch(
            fetch, ["edge", "onprem"], COMMIT, RUN_URL, sent.append,
            interval=0, timeout_minutes=1, log=lambda *_: None,
        )
        self.assertEqual(announced, ["edge", "onprem"])
        self.assertEqual(
            [m["attachments"][0]["content"]["body"][1]["text"] for m in sent],
            ["Stack: **edge**", "Stack: **onprem**"],
        )

    def test_a_failed_post_warns_and_does_not_block_the_rest(self):
        posts = []

        def send(message):
            posts.append(message)
            if len(posts) == 1:
                raise TimeoutError("webhook did not answer")

        logs = []
        announced = nw.watch(
            lambda: [
                {"name": "Apply edge", "status": "waiting"},
                {"name": "Apply onprem", "status": "waiting"},
            ],
            ["edge", "onprem"], COMMIT, RUN_URL, send,
            interval=0, timeout_minutes=1, log=logs.append,
        )
        self.assertEqual(announced, ["onprem"])
        self.assertEqual(len(posts), 2)
        self.assertTrue(any("Teams post failed for stack edge" in line for line in logs))

    def test_missing_webhook_is_a_warning_not_a_failure(self):
        path = fixture_file(JOBS)
        out = io.StringIO()
        with mock.patch.dict(nw.os.environ, {}, clear=True), \
                mock.patch.object(nw.urllib.request, "urlopen", side_effect=AssertionError("no request")), \
                contextlib.redirect_stdout(out):
            code = nw.main(["--watch", "--jobs", path, "--expected", '["edge"]',
                            "--commit-title", COMMIT, "--run-url", RUN_URL])
        self.assertEqual(code, 0)
        self.assertIn("TEAMS_ALERTS_WEBHOOK_URL is not set", out.getvalue())


if __name__ == "__main__":
    unittest.main()
