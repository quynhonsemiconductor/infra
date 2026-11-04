#!/usr/bin/env python3
"""Delete the AWS-era rova alert group and SLO that filter a label value that
never existed on-prem (audit S-H1, 2026-11-04).

WHAT IS DEAD
  * Grafana rule group ``rova (production)`` — six AWS-era rules (5xx, p99,
    slow-count, db-pool, login-failure, worker-failure) whose PromQL filters
    ``deployment_environment_name="production"``. On-prem emits ``prod``/
    ``dev``, so every one evaluated NoData and, with ``no_data_state = OK``,
    reported healthy forever. The working replacements are
    ``rova-prod-http-5xx-rate`` (prod-http-5xx.tf) plus the prod app signals.
  * SLO ``HTTP availability (production)`` — same ``production`` selector in
    its success/total metrics, so the SLO and its burn alerts were dead too.

WHY A SCRIPT AND NOT TERRAFORM: neither object is in any state this repo can
reach (the rova prod stack is the closed AWS-era account, and these objects
were created by hand/old Terraform). Importing them only to delete them needs
two applies and leaves a fragile import in the graph; the Grafana provisioning
API deletes exactly these objects in one reviewed run.

USAGE (dry run first; it prints every match and changes nothing):
    GRAFANA_ALERTS_TOKEN=... python3 scripts/prune_dead_rova_alerts.py
    GRAFANA_ALERTS_TOKEN=... python3 scripts/prune_dead_rova_alerts.py --apply

GRAFANA_URL defaults to https://qnsc.grafana.net. The token needs permission
to read/delete Grafana-managed alert rules and SLOs (the terraform service
account has it).

The script is deliberately narrow: exact group title and exact SLO name. It
does not pattern-match, so it cannot delete a rule that merely mentions rova.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

RULE_GROUP = "rova (production)"
SLO_NAME = "HTTP availability (production)"


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


def main() -> int:
    apply = "--apply" in sys.argv[1:]
    token = os.environ.get("GRAFANA_ALERTS_TOKEN")
    base = os.environ.get("GRAFANA_URL", "https://qnsc.grafana.net").rstrip("/")
    if not token:
        print("GRAFANA_ALERTS_TOKEN is not set", file=sys.stderr)
        return 2

    failures = 0
    try:
        rules = _request("GET", f"{base}/api/v1/provisioning/alert-rules", token)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
        print(f"cannot list alert rules: {error}", file=sys.stderr)
        return 2

    matched = [
        rule
        for rule in (rules if isinstance(rules, list) else [])
        if isinstance(rule, dict) and rule.get("ruleGroup") == RULE_GROUP
    ]
    print(f"alert group {RULE_GROUP!r}: {len(matched)} rule(s)")
    for rule in matched:
        uid = rule.get("uid")
        print(f"  {'DELETE' if apply else 'would delete'} {rule.get('title')} (uid={uid})")
        if apply and uid:
            try:
                _request("DELETE", f"{base}/api/v1/provisioning/alert-rules/{uid}", token)
            except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
                failures += 1
                print(f"    FAILED: {error}", file=sys.stderr)

    try:
        payload = _request("GET", f"{base}/api/v1/slo", token)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
        print(f"cannot list SLOs: {error}", file=sys.stderr)
        return 1

    slos = [slo for slo in _slos(payload) if slo.get("name") == SLO_NAME]
    print(f"SLO {SLO_NAME!r}: {len(slos)} match(es)")
    for slo in slos:
        uuid = slo.get("uuid") or slo.get("id")
        print(f"  {'DELETE' if apply else 'would delete'} {slo.get('name')} (uuid={uuid})")
        if apply and uuid:
            try:
                _request("DELETE", f"{base}/api/v1/slo/{uuid}", token)
            except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
                failures += 1
                print(f"    FAILED: {error}", file=sys.stderr)

    if not apply:
        print("\ndry run: nothing changed. Re-run with --apply to delete.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
