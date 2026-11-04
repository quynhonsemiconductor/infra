#!/usr/bin/env python3
"""Delete the AWS-era rova alert group and SLO that filter a label value that
never existed on-prem (audit S-H1, 2026-11-04).

WHAT IS DEAD
  * Grafana rule group ``rova (production)`` — six AWS-era rules whose PromQL
    filters ``deployment_environment_name="production"``. On-prem emits
    ``prod``/``dev``, so every one evaluated NoData and, with
    ``no_data_state = OK``, reported healthy forever. The working replacements
    are ``rova-prod-http-5xx-rate`` (prod-http-5xx.tf) plus the prod signals.
  * SLO ``HTTP availability (production)`` — same ``production`` selector, so
    the SLO and its burn alerts were dead too.

WHY A SCRIPT AND NOT TERRAFORM: neither object is in any state this repo can
reach (the rova prod stack is the closed AWS-era account). Importing them only
to delete them needs two applies and leaves a fragile import in the graph; the
Grafana provisioning API deletes exactly these objects in one reviewed run.

SAFETY, deliberately paranoid:
  * The six rule TITLES and the folder UID are pinned. If the matched set is
    not EXACTLY those six — missing, extra, wrong folder — the script aborts
    before deleting anything and prints the difference.
  * A matched rule without a `uid` is a failure, never silently skipped.
  * ``--apply`` also requires ``--confirm "DELETE rova (production)"``.

USAGE (dry run first; prints every match and changes nothing):
    GRAFANA_DELETE_TOKEN=... python3 scripts/prune_dead_rova_alerts.py
    GRAFANA_DELETE_TOKEN=... python3 scripts/prune_dead_rova_alerts.py \
        --apply --confirm "DELETE rova (production)"

``GRAFANA_DELETE_TOKEN`` should be a token scoped to delete rules/SLOs, not the
daily alerting-health token. ``GRAFANA_ALERTS_TOKEN`` is accepted as a
fallback. ``GRAFANA_URL`` defaults to https://qnsc.grafana.net.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

RULE_GROUP = "rova (production)"
SLO_NAME = "HTTP availability (production)"
CONFIRM_PHRASE = "DELETE rova (production)"

# QNSC/Alerts (imported as "0:efwpy0l5x8nwgb" in live/observability-alerting).
# Override only if the group really lives in another folder.
DEFAULT_FOLDER_UID = "efwpy0l5x8nwgb"

# The six AWS-era titles, generated as <product>-<env>-<rule name> by
# tf-modules//observability-alerts. Order is irrelevant; the SET must match.
EXPECTED_RULES = {
    "rova-production-auth-login-failure-rate",
    "rova-production-db-pool-contention",
    "rova-production-http-5xx-rate",
    "rova-production-http-p99-latency",
    "rova-production-http-slow-request-count",
    "rova-production-worker-job-failure-rate",
}


def _request(method: str, url: str, token: str) -> object:
    request = urllib.request.Request(
        url, method=method, headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
    return json.loads(body.decode("utf-8")) if body else None


def _slos(payload: object) -> list[dict]:
    """Accept both list shapes the SLO API has used (`slo` and `slos`)."""
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        for key in ("slos", "slo", "items"):
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    return []


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply", action="store_true", help="delete; without it, dry run"
    )
    parser.add_argument(
        "--confirm",
        default="",
        help=f'must equal "{CONFIRM_PHRASE}" together with --apply',
    )
    parser.add_argument(
        "--folder-uid",
        default=DEFAULT_FOLDER_UID,
        help=f"folder holding the group (default {DEFAULT_FOLDER_UID} = QNSC/Alerts)",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.apply and args.confirm != CONFIRM_PHRASE:
        print(
            f"--apply requires --confirm '{CONFIRM_PHRASE}' (got {args.confirm!r})",
            file=sys.stderr,
        )
        return 2

    token = os.environ.get("GRAFANA_DELETE_TOKEN") or os.environ.get(
        "GRAFANA_ALERTS_TOKEN"
    )
    base = os.environ.get("GRAFANA_URL", "https://qnsc.grafana.net").rstrip("/")
    if not token:
        print("GRAFANA_DELETE_TOKEN (or GRAFANA_ALERTS_TOKEN) is not set", file=sys.stderr)
        return 2

    try:
        rules = _request("GET", f"{base}/api/v1/provisioning/alert-rules", token)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
        print(f"cannot list alert rules: {error}", file=sys.stderr)
        return 2

    matched = [
        rule
        for rule in (rules if isinstance(rules, list) else [])
        if isinstance(rule, dict)
        and (rule.get("folderUID") or rule.get("folderUid")) == args.folder_uid
        and rule.get("ruleGroup") == RULE_GROUP
    ]
    found = {str(rule.get("title")) for rule in matched}
    print(
        f"group {RULE_GROUP!r} in folder {args.folder_uid}: "
        f"{len(matched)} rule(s), titles {sorted(found)}"
    )
    if found != EXPECTED_RULES:
        print("REFUSING: the matched rule set is not the pinned six.", file=sys.stderr)
        print(f"  missing: {sorted(EXPECTED_RULES - found)}", file=sys.stderr)
        print(f"  unexpected: {sorted(found - EXPECTED_RULES)}", file=sys.stderr)
        return 2
    missing_uid = [rule.get("title") for rule in matched if not rule.get("uid")]
    if missing_uid:
        print(f"REFUSING: matched rule(s) without uid: {missing_uid}", file=sys.stderr)
        return 2

    failures = 0
    for rule in matched:
        print(
            f"  {'DELETE' if args.apply else 'would delete'} "
            f"{rule['title']} (uid={rule['uid']})"
        )
        if args.apply:
            try:
                _request(
                    "DELETE",
                    f"{base}/api/v1/provisioning/alert-rules/{rule['uid']}",
                    token,
                )
            except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
                failures += 1
                print(f"    FAILED: {error}", file=sys.stderr)

    try:
        payload = _request("GET", f"{base}/api/v1/slo", token)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
        print(f"cannot list SLOs: {error}", file=sys.stderr)
        return 1

    slos = [
        slo
        for slo in _slos(payload)
        if (slo.get("name") or slo.get("title")) == SLO_NAME
    ]
    print(f"SLO {SLO_NAME!r}: {len(slos)} match(es)")
    if len(slos) > 1:
        print("REFUSING: more than one SLO matches the pinned name.", file=sys.stderr)
        return 2
    for slo in slos:
        uuid = slo.get("uuid") or slo.get("id")
        if not uuid:
            print("REFUSING: matched SLO has no uuid/id.", file=sys.stderr)
            return 2
        print(
            f"  {'DELETE' if args.apply else 'would delete'} "
            f"{slo.get('name') or slo.get('title')} (uuid={uuid})"
        )
        if args.apply:
            try:
                _request("DELETE", f"{base}/api/v1/slo/{uuid}", token)
            except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
                failures += 1
                print(f"    FAILED: {error}", file=sys.stderr)

    if not args.apply:
        print("\ndry run: nothing changed. Re-run with --apply and --confirm.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
