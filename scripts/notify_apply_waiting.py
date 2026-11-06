#!/usr/bin/env python3
"""Announce an apply that is waiting for the production environment reviewer.

WHY. Every apply job in infra-apply.yml runs in the GitHub Environment `production` and
blocks on the owner's approval before it starts. Nothing outside the run page says so:
the apply for infra#338 (run 41778707810) waited 2h10m on 2026-11-04. That is not only late.
The workflow's concurrency group keeps a single pending slot, so a newer queued run
cancels the older pending one -- a forgotten approval is silently dropped, not retried.

WHAT. While an infra-apply run is live, watch its jobs through the Actions API. The
first time an `Apply <stack>` job reports status `waiting` (the environment gate), post
one Adaptive Card to the platform Teams channel with the stack, the commit title and
the run link. Exit once every apply job of the run has been announced or has finished.

The webhook is TEAMS_ALERTS_WEBHOOK_URL, the Teams *Workflows* webhook alerting-health.yml
already uses: it answers 202 to any body and posts nothing unless the body is an Adaptive
Card message. The value comes from the environment and is never printed, logged or put on
the command line.

NOTIFICATION IS BEST EFFORT. A missing webhook, a rejected post or an API error only
prints a warning; it never fails the run and never holds back an apply.

DRY RUN. `--dry-run --jobs <actions-jobs.json> --expected <stacks>` prints the exact
request bodies to stdout and makes no request. scripts/test_notify_apply_waiting.py runs
that path over a captured jobs fixture, so the card shape is proven without a webhook.

Usage in the workflow:
  python3 scripts/notify_apply_waiting.py --watch --repo "$REPO" --run-id "$RUN_ID" \\
      --expected "$CHANGED" --commit-title "$TITLE" --run-url "$RUN_URL"
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

APPLY_PREFIX = "Apply "
API = "https://api.github.com"


def stack_of_job(name: str):
    """The stack a workflow job announces, or None.

    infra-apply.yml names every apply job "Apply <stack>" and every other job
    something else ("Plan <stack>", "Plan summary", ...). The stack is the exact
    name the workflow and the docs use: lowercase, no alias table to drift.
    """
    if not name.startswith(APPLY_PREFIX):
        return None
    stack = name[len(APPLY_PREFIX) :].strip().lower()
    return stack or None


def parse_expected(value: str) -> list[str]:
    """Accept the gate's JSON array (`["edge","onprem"]`) or a comma list."""
    value = (value or "").strip()
    if not value:
        return []
    if value.startswith("["):
        parsed = json.loads(value)
        return [str(item).strip().lower() for item in parsed if str(item).strip()]
    return [item.strip().lower() for item in value.split(",") if item.strip()]


def build_card(stack: str, commit_title: str, run_url: str) -> dict:
    """One Adaptive Card: what waits, for which commit, and where to approve it."""
    return {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": [
            {
                "type": "TextBlock",
                "size": "Medium",
                "weight": "Bolder",
                "wrap": True,
                "text": f"Infra apply waiting for approval: {stack}",
            },
            {
                "type": "TextBlock",
                "wrap": True,
                "text": f"Stack: **{stack}**",
            },
            {
                "type": "TextBlock",
                "wrap": True,
                "isSubtle": True,
                "text": f"Commit: {commit_title}",
            },
            {
                "type": "TextBlock",
                "wrap": True,
                "isSubtle": True,
                "text": (
                    "Only one run per concurrency group can be pending: a newer run "
                    "cancels this one. Approve or reject promptly."
                ),
            },
        ],
        "actions": [
            {"type": "Action.OpenUrl", "title": "Review and approve", "url": run_url}
        ],
    }


def build_message(stack: str, commit_title: str, run_url: str) -> dict:
    return {
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "contentUrl": None,
                "content": build_card(stack, commit_title, run_url),
            }
        ],
    }


def waiting_stacks(jobs: list[dict], expected: list[str]) -> list[str]:
    """Stacks whose apply job is at the environment gate right now, in job order."""
    want = set(expected)
    found = []
    for job in jobs:
        stack = stack_of_job(job.get("name", ""))
        if stack and stack in want and job.get("status") == "waiting":
            if stack not in found:
                found.append(stack)
    return found


def finished_stacks(jobs: list[dict]) -> set[str]:
    """Apply jobs that have reached a terminal state and will never wait again."""
    done = set()
    for job in jobs:
        stack = stack_of_job(job.get("name", ""))
        if stack and job.get("status") == "completed":
            done.add(stack)
    return done


def fetch_jobs(repo: str, run_id: str, token: str) -> list[dict]:
    """Every job of the run (the API paginates at 100; this workflow has ~12)."""
    request = urllib.request.Request(
        f"{API}/repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "qnsc-infra-notify-apply-waiting",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response).get("jobs", [])


def post(webhook: str, message: dict) -> None:
    """POST one card. Raises on failure; the caller turns that into a warning."""
    request = urllib.request.Request(
        webhook,
        data=json.dumps(message).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        response.read()


def watch(fetch, expected, commit_title, run_url, send, interval, timeout_minutes, log=print):
    """Announce each apply job once, then stop.

    Returns the stacks announced. `fetch()` returns the run's job list; `send`
    takes a message dict. Stops when every expected stack has either been announced
    or reached a terminal state, or after the timeout -- whichever comes first.
    """
    pending = set(expected)
    announced: list[str] = []
    deadline = time.monotonic() + timeout_minutes * 60

    while pending:
        try:
            jobs = fetch()
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            log(f"::warning::could not read the run's jobs: {error}")
            jobs = []
        else:
            for stack in waiting_stacks(jobs, sorted(pending)):
                if stack in announced:
                    continue
                try:
                    send(build_message(stack, commit_title, run_url))
                    log(f"approval card posted for stack {stack}")
                    announced.append(stack)
                except (urllib.error.URLError, TimeoutError, ValueError) as error:
                    log(f"::warning::Teams post failed for stack {stack}: {error}")
                pending.discard(stack)
            pending -= finished_stacks(jobs)

        if not pending:
            break
        if time.monotonic() >= deadline:
            log(f"::warning::stopped watching with stacks still unannounced: {sorted(pending)}")
            break
        time.sleep(interval)

    return announced


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--watch", action="store_true", help="poll the run until every apply job is announced or finished")
    parser.add_argument("--dry-run", action="store_true", help="print the request bodies; make no request")
    parser.add_argument("--jobs", help="read the Actions jobs JSON from this file instead of the API (fixtures)")
    parser.add_argument("--expected", default="", help="stacks the gate selected (JSON array or comma list)")
    parser.add_argument("--commit-title", default="", help="first line of the head commit")
    parser.add_argument("--run-url", default="", help="link to the run")
    parser.add_argument("--repo", default="", help="owner/name (API mode)")
    parser.add_argument("--run-id", default="", help="run id (API mode)")
    parser.add_argument("--interval", type=int, default=20, help="seconds between polls")
    parser.add_argument("--timeout-minutes", type=int, default=60, help="give up after this long")
    args = parser.parse_args(argv)

    expected = parse_expected(args.expected)

    if args.jobs:
        with open(args.jobs, encoding="utf-8") as handle:
            jobs = json.load(handle).get("jobs", [])
        fetch = lambda: jobs  # noqa: E731 - fixture, never changes
    else:
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
        if not args.repo or not args.run_id or not token:
            parser.error("API mode needs --repo, --run-id and GH_TOKEN (or use --jobs)")
        fetch = lambda: fetch_jobs(args.repo, args.run_id, token)  # noqa: E731

    if args.dry_run:
        messages = [
            build_message(stack, args.commit_title, args.run_url)
            for stack in waiting_stacks(fetch(), expected)
        ]
        print(json.dumps(messages))
        return 0

    webhook = os.environ.get("TEAMS_ALERTS_WEBHOOK_URL", "")
    if not webhook:
        print("::warning::TEAMS_ALERTS_WEBHOOK_URL is not set; no approval card was posted")
        return 0

    def send(message):
        post(webhook, message)

    if args.watch:
        watch(fetch, expected, args.commit_title, args.run_url, send, args.interval, args.timeout_minutes)
    else:
        for stack in waiting_stacks(fetch(), expected):
            send(build_message(stack, args.commit_title, args.run_url))
    return 0


if __name__ == "__main__":
    sys.exit(main())
