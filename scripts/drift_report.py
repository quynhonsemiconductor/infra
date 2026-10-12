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

WHAT STILL FAILS THE JOB: a resource deleted outside OpenTofu (any type), and a change to a DNS / edge / mail-identity /
certificate / key resource (the same list destructive_guard.py protects) that touches a REAL attribute: not one the provider
computes by itself (Cloudflare created_on / modified_on / status ...), and not an empty-equivalent flip (tags null -> []).
Those two kinds appeared on every DNS record and the R2 custom domain on 2026-10-13 with an empty plan, and failed the job
for nothing. A real edit to a managed attribute also shows in the plain `plan` pass, which fails on any change.
Everything else is listed in the job summary.
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from destructive_guard import is_protected  # noqa: E402  (same directory)


# Attributes a provider COMPUTES and updates by itself: they change without anyone touching the resource and are not part
# of any configuration, so a refresh-only difference in them only ever means "state is catching up". Cloudflare only: for
# other providers a `status` can be meaningful (an ACM certificate going from ISSUED to EXPIRED), so nothing is assumed.
CLOUDFLARE_COMPUTED = frozenset({
    "created_on", "modified_on", "created_at", "modified_at", "updated_at",
    "status",          # r2 custom domain: ownership pending -> active, ssl initializing -> active, a few minutes after create
    "zone_name", "metadata", "proxiable", "hostname",
})


def _norm(value):
    """null, [], {} and "" are the same 'nothing': a provider upgrade or an import turns one into another (tags null -> [])."""
    if isinstance(value, dict):
        value = {k: _norm(v) for k, v in value.items()}
        value = {k: v for k, v in value.items() if v is not None}
    elif isinstance(value, list):
        value = [_norm(v) for v in value]
    return None if value in (None, [], {}, "") else value


def meaningful_attrs(rtype: str, change: dict) -> list[str] | None:
    """Attributes that really changed. None = cannot tell (no before/after in the plan): the caller treats it as meaningful."""
    before, after = change.get("before"), change.get("after")
    if not isinstance(before, dict) or not isinstance(after, dict):
        return None
    ignore = CLOUDFLARE_COMPUTED if rtype.startswith("cloudflare_") else frozenset()
    return sorted(k for k in set(before) | set(after)
                  if k not in ignore and _norm(before.get(k)) != _norm(after.get(k)))


def classify(doc: dict) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    significant, informational = [], []
    for rd in doc.get("resource_drift") or []:
        change = rd.get("change") or {}
        actions = change.get("actions") or []
        if actions in ([], ["no-op"]):
            continue
        address, rtype = rd.get("address") or "<unknown>", rd.get("type") or ""
        if "delete" in actions:
            significant.append((address, "DELETED outside OpenTofu"))
            continue
        verb = "/".join(actions)
        attrs = meaningful_attrs(rtype, change)
        if is_protected(rtype, address) and (attrs is None or attrs):
            significant.append((address, f"{verb} ({', '.join(attrs) if attrs else 'cannot tell which attributes'})"))
        else:
            informational.append((address, verb + (f" ({', '.join(attrs)})" if attrs else " (computed / empty-equivalent only)")))
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
