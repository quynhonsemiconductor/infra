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

The second check is the S-H1 guard: every enabled Prometheus alert rule must have returned
data at least once in the last 7 days. It exists because half the rules once filtered a label
value that does not exist, evaluated NoData and reported OK forever. Findings are WARN (a
pre-launch product is legitimately silent); a rule whose query itself errors is also WARN.

A check that could not run must never read as a check that passed: a missing token is
SKIPPED, and a skip fails the run in CI.

EXIT CODE. Non-zero when the check fails, or when it was skipped in CI, so a scheduled run
turns red and the workflow's alert job opens the issue.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
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


def _get_json(url: str, token: str) -> object:
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def check_alert_rules_have_data() -> tuple[list, list]:
    """Every enabled Prometheus alert rule must have returned data in 7 days.

    The 2026-11-04 audit found ~half the rules filtering a label value that does
    not exist (``deployment_environment_name="production"`` while on-prem emits
    ``prod``). They evaluated NoData and, with ``no_data_state = OK``, reported
    healthy forever. A rule can only be checked for "has data" by asking its
    datasource: Grafana's rule API carries the expression but not a 7-day data
    history. So each rule's expression is run over the last 7 days at a 6-hour
    step; an empty result is the finding.

    WARN, not FAIL: several rules are silent until their product or cluster
    exists (opshub/kb prod before launch), and paging on that would be noise. A
    WARN keeps the job green while putting the list in the run summary every day.

    NOTHING IS SKIPPED SILENTLY: a paused rule, a non-Prometheus datasource and
    a rule with no query node each produce a WARN saying why it was not checked.
    The sweep also has a total time budget (`ALERTING_HEALTH_BUDGET_SECONDS`,
    default 60); when it runs out, the remaining rules are reported as
    unchecked rather than letting the daily job run long.
    """
    token = os.environ.get("GRAFANA_ALERTS_TOKEN")
    url = os.environ.get("GRAFANA_URL", "https://qnsc.grafana.net").rstrip("/")
    if not token:
        raise Skipped("GRAFANA_ALERTS_TOKEN is not set in the environment")
    budget = float(os.environ.get("ALERTING_HEALTH_BUDGET_SECONDS", "60"))
    deadline = time.monotonic() + budget

    try:
        rules = _get_json(f"{url}/api/v1/provisioning/alert-rules", token)
    except urllib.error.HTTPError as error:
        return [("Alert rules", f"cannot list rules: HTTP {error.code}")], []
    except (urllib.error.URLError, TimeoutError) as error:
        return [("Alert rules", f"{url} unreachable: {error}")], []
    if not isinstance(rules, list):
        return [("Alert rules", "unexpected provisioning response")], []

    end = int(time.time())
    start = end - 7 * 24 * 3600
    warns: list[tuple[str, str]] = []
    for index, rule in enumerate(rules):
        if time.monotonic() >= deadline:
            warns.append(
                (
                    "Alert rules",
                    f"time budget {budget:.0f}s exhausted; "
                    f"{len(rules) - index} rule(s) not checked",
                )
            )
            break
        if not isinstance(rule, dict):
            warns.append(("Alert rules", f"entry {index} is not an object; not checked"))
            continue
        folder = rule.get("folderUID") or rule.get("folderUid") or "?"
        rule_name = f"{folder}/{rule.get('ruleGroup', '?')}/{rule.get('title', '?')}"
        if rule.get("isPaused"):
            warns.append((rule_name, "paused — no data check"))
            continue
        for node in rule.get("data") or []:
            uid = node.get("datasourceUid")
            model = node.get("model") or {}
            datasource = model.get("datasource") or {}
            if not uid or uid == "__expr__" or not model.get("expr"):
                continue
            # Loki rules are log queries with a different proxy path and a
            # different response shape; say so rather than silently skipping.
            if datasource.get("type") != "prometheus":
                warns.append(
                    (
                        rule_name,
                        f"not checked: datasource type {datasource.get('type')!r}",
                    )
                )
                break
            query = urllib.parse.urlencode(
                {"query": model["expr"], "start": start, "end": end, "step": 21600}
            )
            try:
                payload = _get_json(
                    f"{url}/api/datasources/proxy/uid/{uid}/api/v1/query_range?{query}",
                    token,
                )
            except urllib.error.HTTPError as error:
                warns.append((rule_name, f"query failed: HTTP {error.code}"))
                break
            except (urllib.error.URLError, TimeoutError) as error:
                warns.append((rule_name, f"query failed: {error}"))
                break
            result = ((payload or {}).get("data") or {}).get("result")
            if not result:
                warns.append(
                    (rule_name, "no data in 7 days — the selector or label value may not exist")
                )
            break
        else:
            warns.append((rule_name, "no query node; not checked"))
    return [], warns


CHECKS = [
    ("Grafana token", check_grafana),
    ("Alert rules have data", check_alert_rules_have_data),
]


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
