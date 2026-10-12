#!/usr/bin/env python3
"""Classify the drift a `tofu plan -refresh-only` found, so the nightly job alerts on signal and not on noise.

    tofu show -json refresh.tfplan | python3 scripts/drift_report.py
    exit 0  no drift
    exit 3  drift, INFORMATIONAL only (printed, does not fail the job)
    exit 2  drift that matters: a resource was DELETED outside OpenTofu, or a DNS/identity resource changed
    exit 1  input is not a plan (fail closed: never read as "no drift")

WHY. A refresh-only plan reports every attribute the provider computes differently from the state: an ElastiCache
group gaining `user_group_ids = []`, a security group listing the ingress rules that separate rule resources attached,
a tag map going from null to `{}`. The unapplied-config pass (`tofu plan`) still sees every change to an attribute the
configuration manages, so this noise adds no safety, only a job that is red every night. On 2026-10-09 that nightly red
(edge and storage errored for lack of a token) is why three days of missing DNS records were not noticed. An alarm that
fires every night is muted; this makes the red mean something.

WHAT STILL FAILS THE JOB: a resource deleted outside OpenTofu (any type), and any change to a DNS / edge / mail-identity /
certificate / key resource (the same list destructive_guard.py protects). Everything else is listed in the job summary.
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from destructive_guard import is_protected  # noqa: E402  (same directory)


def classify(doc: dict) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    significant, informational = [], []
    for rd in doc.get("resource_drift") or []:
        actions = (rd.get("change") or {}).get("actions") or []
        if actions in ([], ["no-op"]):
            continue
        address, rtype = rd.get("address") or "<unknown>", rd.get("type") or ""
        verb = "DELETED outside OpenTofu" if "delete" in actions else "/".join(actions)
        if "delete" in actions or is_protected(rtype, address):
            significant.append((address, verb))
        else:
            informational.append((address, verb))
    return significant, informational


def main() -> int:
    try:
        doc = json.loads(sys.stdin.read())
    except Exception as exc:  # noqa: BLE001
        print(f"drift_report: input is not JSON ({exc}); refusing to read that as 'no drift'.")
        return 1
    if not isinstance(doc, dict) or "format_version" not in doc:
        print("drift_report: input is not a tofu plan (no format_version); refusing to read that as 'no drift'.")
        return 1
    significant, informational = classify(doc)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = []
    if significant:
        lines.append("External drift that MATTERS (deleted outside OpenTofu, or DNS/identity):")
        lines += [f"  {a}  {v}" for a, v in sorted(significant)]
    if informational:
        lines.append("External drift, informational (provider-computed attributes; the unapplied-config pass covers managed ones):")
        lines += [f"  {a}  {v}" for a, v in sorted(informational)]
    if lines:
        print("\n".join(lines))
        if summary:
            with open(summary, "a", encoding="utf-8") as fh:
                fh.write("```\n" + "\n".join(lines) + "\n```\n")
    if significant:
        return 2
    return 3 if informational else 0


if __name__ == "__main__":
    sys.exit(main())
