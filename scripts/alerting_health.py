#!/usr/bin/env python3
"""Report alerting paths that exist but cannot deliver.

WHY THIS EXISTS. On 2026-09-13 an audit found that essentially none of this account's
alerting could reach a human, and every part of that was invisible:

  * EVERY SNS alarm topic in the account had ZERO subscriptions. Alarms fired into
    nothing. Cause: `var.alert_emails` / `var.alarm_emails` defaulted to `[]`.
  * The account budget had NO notifications at all, so a $500 ceiling could not be hit.
  * The cost-anomaly monitor had NO subscriber.
  * Six RDS alarms had sat in INSUFFICIENT_DATA for months because they were created with
    an RDS *resource id* (`db-F35NKOG…`) where CloudWatch publishes under
    `DBInstanceIdentifier` (`rova-prod`). They appeared configured and were dead.
  * The Grafana service-account token stopped being accepted around 2026-09-11. Nothing
    noticed for two days; it surfaced only because an unrelated `tofu plan` failed on it.

Every one of those is a control that LOOKS present in the console and in state. `tofu plan`
reports no drift, because nothing drifted — the configuration genuinely says what it says.
The failure is semantic, not structural, so no plan-time check can see it.

AND SOMETHING WORSE THAN A GAP: AWS DELETES UNCONFIRMED EMAIL SUBSCRIPTIONS after roughly
three days. So an SNS email subscription is not a durable control — it is a control that
silently expires unless a human clicked a link. rova's stack had the correct default
`nghiavt@qnsc.vn` for weeks and still delivered nothing for exactly this reason. A
PendingConfirmation subscription therefore counts as a finding here, not as progress.

WHAT THIS DOES NOT DO. It does not verify that an alarm's THRESHOLD is sensible, or that
its metric is the right one. Those are judgement calls. It verifies the mechanical
delivery chain only: alarm -> action -> topic -> confirmed subscriber. That chain was
broken at three separate links on 2026-09-13, and each break was independently silent.

EXIT CODE. Non-zero when any FAIL-level finding exists, so a scheduled run turns red and
GitHub emails the actor — the same notification-by-CI-failure choice
scripts/unmanaged_resources.py makes, and for the same reason: a schedule has no PR to
annotate. WARN-level findings (pending confirmations) do not fail the run on their own,
because immediately after an apply they are the expected state; they fail only once they
are the ONLY thing standing between an alarm and a person.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

REGION = os.environ.get("AWS_REGION", "ap-southeast-1")

# Budgets and Cost Explorer are global services with us-east-1 endpoints. Querying them in
# ap-southeast-1 returns empty rather than erroring, which would make this script report
# "no budgets" and pass — a false green in exactly the control we are trying to protect.
GLOBAL_REGION = "us-east-1"

# How long an alarm may sit in INSUFFICIENT_DATA before it is treated as broken rather than
# merely quiet. Idled environments legitimately report INSUFFICIENT_DATA (see
# observability's `environment_idle`), so this cannot be zero. Seven days is longer than any
# scheduled idle window here and far shorter than the six months the RDS dimension bug
# survived.
STALE_ALARM_DAYS = 7

# Topics that legitimately have no email subscriber, with a reason. Same discipline as
# unmanaged_resources.ALLOWLIST: an entry must say why, so this cannot become a place
# findings go to be forgotten.
ALLOWLIST: dict[str, str] = {
    # SES bounce/complaint topics deliver to an SQS queue that the application drains, not
    # to a person. A human subscriber here would be noise on every bounced email.
    "ses-bounce-events": "delivers to SQS for the app to process, not to a human",
}


class Skipped(Exception):
    """A check could not run, as distinct from a check that passed.

    Conflating the two is the failure mode this whole script is a reaction to: an RDS alarm
    that could never leave INSUFFICIENT_DATA still rendered as a configured alarm, and an
    SNS topic with no subscriber still rendered as a wired-up notification. So "I could not
    look" gets its own level and never prints as clean.
    """


def aws(*args: str, region: str | None = None) -> object:
    """Run an AWS CLI command and parse its JSON. The CLI is preinstalled on GitHub
    runners, so this script needs no pip install — matching scripts/unmanaged_resources.py.

    RAISES on failure rather than returning None. It used to return None, and every caller
    then treated "the call failed" identically to "the call succeeded and found nothing" —
    so an expired session made this script report `no CloudWatch alarms exist at all` and
    `no anomaly monitor configured`, three confident findings about an account it had not
    managed to read. Measured 2026-09-14 with a bogus profile.

    That is precisely the false signal this file exists to catch, one level up: a control
    that reports a state it did not verify. `Skipped` propagates to main(), which prints
    SKIPPED and fails the run in CI, where a credential failure is itself a broken control.
    """
    cmd = ["aws", *args, "--region", region or REGION, "--output", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise Skipped(f"`{' '.join(cmd[:4])}…` failed: {result.stderr.strip()[:200]}")
    return json.loads(result.stdout or "null")


def allowlisted(topic_arn: str) -> str | None:
    for fragment, reason in ALLOWLIST.items():
        if fragment in topic_arn:
            return reason
    return None


# ── Checks ───────────────────────────────────────────────────────────────────
# Each returns (fail_findings, warn_findings), both lists of (subject, detail).


def check_alarm_delivery() -> tuple[list, list]:
    """The core chain: every alarm must have an action, and every topic it actions must
    have a CONFIRMED subscriber.

    Checked together rather than as two passes because the interesting question is not
    "does this topic have subscribers" but "can this ALARM reach anyone" — a topic with no
    subscribers matters only if something actions it, and an unactioned alarm is invisible
    no matter how healthy its topics are.
    """
    fails: list[tuple[str, str]] = []
    warns: list[tuple[str, str]] = []

    alarms = aws("cloudwatch", "describe-alarms") or {}
    metric_alarms = alarms.get("MetricAlarms", []) + alarms.get("CompositeAlarms", [])
    if not metric_alarms:
        fails.append(("(account)", "no CloudWatch alarms exist at all"))
        return fails, warns

    # Cache subscription lookups: many alarms share one topic.
    topic_state: dict[str, tuple[int, int]] = {}

    def subscribers(arn: str) -> tuple[int, int]:
        if arn not in topic_state:
            subs = (aws("sns", "list-subscriptions-by-topic", "--topic-arn", arn) or {}).get(
                "Subscriptions", []
            )
            confirmed = sum(
                1 for s in subs if "PendingConfirmation" not in s.get("SubscriptionArn", "")
            )
            pending = len(subs) - confirmed
            topic_state[arn] = (confirmed, pending)
        return topic_state[arn]

    unactioned: list[str] = []
    for alarm in metric_alarms:
        name = alarm.get("AlarmName", "?")
        actions = alarm.get("AlarmActions") or []
        if not actions:
            unactioned.append(name)
            continue
        for arn in actions:
            if not arn.startswith("arn:aws:sns:"):
                continue
            reason = allowlisted(arn)
            if reason:
                continue
            confirmed, pending = subscribers(arn)
            if confirmed:
                continue
            topic = arn.rsplit(":", 1)[-1]
            if pending:
                warns.append(
                    (
                        f"`{topic}`",
                        f"{pending} subscription(s) still PendingConfirmation — AWS deletes "
                        f"these after ~3 days, so `{name}` currently reaches nobody",
                    )
                )
            else:
                fails.append(
                    (f"`{topic}`", f"no subscriptions at all — `{name}` fires into nothing")
                )

    if unactioned:
        shown = ", ".join(f"`{n}`" for n in sorted(unactioned)[:6])
        extra = f" (+{len(unactioned) - 6} more)" if len(unactioned) > 6 else ""
        fails.append(
            (
                "alarms with no action",
                f"{len(unactioned)} alarm(s) notify nothing on breach: {shown}{extra}",
            )
        )

    # Deduplicate: one topic breaks many alarms, and repeating it obscures how many
    # DISTINCT things are wrong.
    return _dedupe(fails), _dedupe(warns)


def _dedupe(findings: list[tuple[str, str]]) -> list[tuple[str, str]]:
    seen: set[str] = set()
    out: list[tuple[str, str]] = []
    for subject, detail in findings:
        if subject in seen:
            continue
        seen.add(subject)
        out.append((subject, detail))
    return out


def check_stale_alarms() -> tuple[list, list]:
    """Alarms parked in INSUFFICIENT_DATA long enough that the metric is probably wrong.

    This is the shape of the RDS dimension bug: the alarm existed, referenced a dimension
    value that never publishes, and therefore could never leave INSUFFICIENT_DATA. It read
    as covered on every dashboard for six months.
    """
    warns: list[tuple[str, str]] = []
    cutoff = datetime.now(timezone.utc) - timedelta(days=STALE_ALARM_DAYS)

    alarms = (aws("cloudwatch", "describe-alarms", "--state-value", "INSUFFICIENT_DATA") or {}).get(
        "MetricAlarms", []
    )
    for alarm in alarms:
        stamp = alarm.get("StateUpdatedTimestamp")
        if not stamp:
            continue
        try:
            when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError:
            continue
        if when < cutoff:
            days = (datetime.now(timezone.utc) - when).days
            warns.append(
                (
                    f"`{alarm.get('AlarmName', '?')}`",
                    f"INSUFFICIENT_DATA for {days} days — metric "
                    f"`{alarm.get('MetricName', '?')}` may not publish under the dimensions "
                    "this alarm names",
                )
            )
    return [], warns


def check_budgets() -> tuple[list, list]:
    """A budget with no notification is a number in a console, not a control."""
    fails: list[tuple[str, str]] = []
    account = (aws("sts", "get-caller-identity") or {}).get("Account")
    if not account:
        return [("budgets", "could not resolve account id, so budgets were not checked")], []

    budgets = (
        aws("budgets", "describe-budgets", "--account-id", account, region=GLOBAL_REGION) or {}
    ).get("Budgets", [])
    if not budgets:
        return [("budgets", "no budget exists on this account")], []

    for budget in budgets:
        name = budget.get("BudgetName", "?")
        notifications = (
            aws(
                "budgets",
                "describe-notifications-for-budget",
                "--account-id",
                account,
                "--budget-name",
                name,
                region=GLOBAL_REGION,
            )
            or {}
        ).get("Notifications", [])
        if not notifications:
            fails.append((f"`{name}`", "budget has no notifications — it cannot alert anyone"))
            continue
        # A notification with no subscriber is the same failure one level down.
        for notification in notifications:
            subs = (
                aws(
                    "budgets",
                    "describe-subscribers-for-notification",
                    "--account-id",
                    account,
                    "--budget-name",
                    name,
                    "--notification",
                    json.dumps(notification),
                    region=GLOBAL_REGION,
                )
                or {}
            ).get("Subscribers", [])
            if not subs:
                fails.append(
                    (
                        f"`{name}`",
                        f"{notification.get('NotificationType')} threshold "
                        f"{notification.get('Threshold')} has no subscriber",
                    )
                )
    return _dedupe(fails), []


def check_cost_anomaly() -> tuple[list, list]:
    """Anomaly detection with no subscription detects anomalies and tells nobody."""
    fails: list[tuple[str, str]] = []
    monitors = (aws("ce", "get-anomaly-monitors", region=GLOBAL_REGION) or {}).get(
        "AnomalyMonitors", []
    )
    if not monitors:
        return [("cost anomaly", "no anomaly monitor configured")], []

    subscriptions = (aws("ce", "get-anomaly-subscriptions", region=GLOBAL_REGION) or {}).get(
        "AnomalySubscriptions", []
    )
    if not subscriptions:
        return [
            ("cost anomaly", f"{len(monitors)} monitor(s) exist with no subscription")
        ], []

    for subscription in subscriptions:
        if not subscription.get("Subscribers"):
            fails.append(
                (
                    f"`{subscription.get('SubscriptionName', '?')}`",
                    "anomaly subscription has no subscriber",
                )
            )
    return fails, []


def check_eventbridge_delivery() -> tuple[list, list]:
    """SNS topics that EventBridge rules target.

    A separate check from the alarm chain because it is a separate chain, and the first
    version of this script missed it entirely: `qnsc-security-alerts` carries the root-user
    API and console-login rules, is targeted by EventBridge rather than actioned by a
    CloudWatch alarm, and so passed unexamined while having no confirmed subscriber. The
    root-activity alerting added on 2026-09-13 could have decayed exactly the way the alarm
    topics did, and this script would have called it clean.
    """
    fails: list[tuple[str, str]] = []
    warns: list[tuple[str, str]] = []

    rules = (aws("events", "list-rules") or {}).get("Rules", [])
    for rule in rules:
        name = rule.get("Name")
        if not name:
            continue
        if rule.get("State") != "ENABLED":
            fails.append((f"`{name}`", "EventBridge rule is DISABLED — it matches nothing"))
            continue
        targets = (aws("events", "list-targets-by-rule", "--rule", name) or {}).get("Targets", [])
        for target in targets:
            arn = target.get("Arn", "")
            if not arn.startswith("arn:aws:sns:") or allowlisted(arn):
                continue
            subs = (aws("sns", "list-subscriptions-by-topic", "--topic-arn", arn) or {}).get(
                "Subscriptions", []
            )
            confirmed = sum(
                1 for s in subs if "PendingConfirmation" not in s.get("SubscriptionArn", "")
            )
            if confirmed:
                continue
            topic = arn.rsplit(":", 1)[-1]
            pending = len(subs) - confirmed
            if pending:
                warns.append(
                    (
                        f"`{topic}`",
                        f"{pending} subscription(s) still PendingConfirmation — AWS deletes "
                        f"these after ~3 days, so rule `{name}` reaches nobody",
                    )
                )
            else:
                fails.append(
                    (f"`{topic}`", f"no subscriptions at all — rule `{name}` fires into nothing")
                )
    return _dedupe(fails), _dedupe(warns)


def check_grafana() -> tuple[list, list]:
    """Does the Grafana token still authenticate?

    This is the check that did not exist on 2026-09-11 when the token stopped working.
    Terraform reads Grafana datasources at PLAN time, so an invalid token does not degrade
    alerting quietly — it fails every plan and apply for rova and opshub, blocking all
    infrastructure change. Worth one HTTP call.

    Returns SKIPPED rather than clean when the token is absent. A check that could not run
    must never read as a check that passed: that is the same false-green as an alarm sitting
    in INSUFFICIENT_DATA while looking configured, which is half of why this file exists.
    """
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
            "token is rejected — every rova and opshub plan/apply will fail on the "
            "grafana provider until it is replaced"
            if error.code in (401, 403)
            else f"HTTP {error.code}"
        )
        return [("Grafana token", f"{detail} (`GET /api/datasources/name/{datasource}`)")], []
    except (urllib.error.URLError, TimeoutError) as error:
        return [("Grafana", f"{url} unreachable: {error}")], []


CHECKS = [
    ("Alarm delivery chain", check_alarm_delivery),
    ("EventBridge delivery chain", check_eventbridge_delivery),
    ("Budget notifications", check_budgets),
    ("Cost anomaly subscriptions", check_cost_anomaly),
    ("Grafana token", check_grafana),
    ("Alarms stuck in INSUFFICIENT_DATA", check_stale_alarms),
]


def main() -> int:
    lines: list[str] = [
        "## Alerting health",
        "",
        f"Region `{REGION}` · can each configured alarm actually reach a person?",
        "",
    ]
    total_fail = 0
    total_warn = 0
    skipped: list[tuple[str, str]] = []

    # In CI every secret this needs is provided, so a skip there means the workflow is
    # misconfigured — which is itself a broken control and must not pass. Locally a missing
    # secret is normal and only worth reporting.
    in_ci = bool(os.environ.get("GITHUB_ACTIONS"))

    for label, check in CHECKS:
        try:
            fails, warns = check()
        except Skipped as reason:
            skipped.append((label, str(reason)))
            lines.append(f"- **{label}** — SKIPPED: {reason}")
            continue
        if not fails and not warns:
            lines.append(f"- **{label}** — clean")
            continue
        total_fail += len(fails)
        total_warn += len(warns)
        lines.append("")
        counts = ", ".join(
            part
            for part in (
                f"{len(fails)} failing" if fails else "",
                f"{len(warns)} warning" if warns else "",
            )
            if part
        )
        lines.append(f"### {label} — {counts}")
        lines.append("")
        lines.append("| Level | Subject | Detail |")
        lines.append("| :--- | :--- | :--- |")
        for subject, detail in fails:
            lines.append(f"| FAIL | {subject} | {detail} |")
        for subject, detail in warns:
            lines.append(f"| WARN | {subject} | {detail} |")
        lines.append("")

    lines.append("")
    if total_fail:
        lines.append(
            f"**{total_fail} broken delivery path(s).** An alarm that cannot reach anyone is "
            "worse than no alarm, because it reads as coverage."
        )
    elif total_warn:
        lines.append(
            f"**{total_warn} warning(s), nothing broken.** Pending SNS confirmations expire "
            "in about 3 days — click the confirmation emails before then."
        )
    else:
        lines.append("**Every configured alarm can reach a confirmed subscriber.**")

    if skipped and in_ci:
        lines.append("")
        lines.append(
            f"**{len(skipped)} check(s) could not run in CI.** A control that was not "
            "verified is not a control that passed — fix the workflow's inputs."
        )

    if ALLOWLIST:
        lines.append("")
        lines.append("<details><summary>Allowlisted topics (no human subscriber by design)</summary>")
        lines.append("")
        for fragment, reason in ALLOWLIST.items():
            lines.append(f"- `*{fragment}*` — {reason}")
        lines.append("")
        lines.append("</details>")

    report = "\n".join(lines)
    print(report)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(report + "\n")

    return 1 if total_fail or (skipped and in_ci) else 0


if __name__ == "__main__":
    sys.exit(main())
