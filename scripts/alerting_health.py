#!/usr/bin/env python3
"""Report alerting paths that exist but cannot deliver.

HISTORY. This script used to check the AWS alarm chain (CloudWatch alarm -> SNS topic ->
confirmed subscriber, budgets, cost anomaly, EventBridge rules, RDS changes). Those checks
were removed with the AWS exit (2026-11-02): the account is closed and nothing in
infra monitors AWS any more.

WHAT IS LEFT is the one check that was never AWS: does the Grafana token still
authenticate? Terraform reads Grafana datasources at PLAN time, so an expired token does not
degrade alerting quietly, it fails every plan and apply that touches the grafana provider
(it did, 2026-09-11, and went unnoticed for two days).

A check that could not run must never read as a check that passed: a missing token is
SKIPPED, and a skip fails the run in CI.

EXIT CODE. Non-zero when the check fails, or when it was skipped in CI, so a scheduled run
turns red and the workflow's alert job opens the issue.
"""

from __future__ import annotations

import os
import sys
import urllib.error
import urllib.request


class Skipped(Exception):
    """A check could not run, as distinct from a check that passed."""


def check_grafana() -> tuple[list, list]:
    """Does the Grafana token still authenticate? Returns (fails, warns)."""
    token = os.environ.get("GRAFANA_ALERTS_TOKEN")
    url = os.environ.get("GRAFANA_URL", "https://qnsc.grafana.net")
    datasource = os.environ.get("GRAFANA_DATASOURCE", "grafanacloud-qnsc-prom")
    if not token:
        raise Skipped("GRAFANA_ALERTS_TOKEN is not set in the environment")

    request = urllib.request.Request(
        f"{url}/api/datasources/name/{datasource}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            if response.status == 200:
                return [], []
            return [("Grafana token", f"unexpected HTTP {response.status} from {url}")], []
    except urllib.error.HTTPError as error:
        detail = (
            "token is rejected: every plan/apply on the grafana provider will fail until it is replaced"
            if error.code in (401, 403)
            else f"HTTP {error.code}"
        )
        return [("Grafana token", f"{detail} (`GET /api/datasources/name/{datasource}`)")], []
    except (urllib.error.URLError, TimeoutError) as error:
        return [("Grafana", f"{url} unreachable: {error}")], []


CHECKS = [("Grafana token", check_grafana)]


def main() -> int:
    lines = ["## Alerting health", ""]
    total_fail = 0
    skipped: list[tuple[str, str]] = []
    in_ci = bool(os.environ.get("GITHUB_ACTIONS"))

    for label, check in CHECKS:
        try:
            fails, warns = check()
        except Skipped as reason:
            skipped.append((label, str(reason)))
            lines.append(f"- **{label}**: SKIPPED: {reason}")
            continue
        if not fails and not warns:
            lines.append(f"- **{label}**: clean")
            continue
        total_fail += len(fails)
        lines += ["", f"### {label}", "", "| Level | Subject | Detail |", "| :--- | :--- | :--- |"]
        for subject, detail in fails:
            lines.append(f"| FAIL | {subject} | {detail} |")
        for subject, detail in warns:
            lines.append(f"| WARN | {subject} | {detail} |")

    lines.append("")
    if len(skipped) == len(CHECKS):
        lines.append("**NOTHING WAS VERIFIED.** Every check was skipped.")
    elif total_fail:
        lines.append(f"**{total_fail} finding(s).**")
    else:
        lines.append("**The Grafana token authenticates.**")
    if skipped and in_ci:
        lines.append("A skipped check in CI means the workflow is misconfigured: fix its inputs.")

    report = "\n".join(lines)
    print(report)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(report + "\n")
    return 1 if total_fail or (skipped and in_ci) else 0


if __name__ == "__main__":
    sys.exit(main())
