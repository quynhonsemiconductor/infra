#!/usr/bin/env python3
"""Refuse a plan that DELETES or REPLACES a DNS or identity resource, unless a reviewer said so.

    tofu show -json tfplan | python3 scripts/destructive_guard.py [--allow]

WHY. On 2026-10-09 a provider-lock bump (infra#149) was merged, the apply workflow planned `live/edge`, the plan said

    cloudflare_record.landing["qnsc.vn"] must be replaced   (zone_id: "88f6..." -> null  # forces replacement)  x9

and applied exactly that plan with no review: nine records destroyed, every re-create failed ("required missing zone ID"),
the site, SES DKIM/MAIL FROM and the ACM validation record were down for three days and nobody noticed
(docs/incidents/2026-10-09-edge-dns.md). The plan comment on the PR showed it too; a red/green check did not.

A destroyed DNS record or identity is not rebuilt by "re-running the apply": the re-create can fail for a reason the
destroy did not (here, the same null zone id), and what the world sees in between is an outage. So these types get the
same treatment `ci/actions/plan-guard` gives data: the plan itself is read, and a delete or replace fails the job.

WHAT COUNTS (a change that can take something outward-facing down or change who we are). By type PREFIX:
  DNS / edge     cloudflare_record, cloudflare_dns_record, cloudflare_pages_*, cloudflare_r2_* (buckets and custom
                 domains), cloudflare_zone*, cloudflare_ruleset, cloudflare_turnstile_*, cloudflare_waf_*,
                 cloudflare_custom_hostname, cloudflare_certificate_pack, cloudflare_origin_ca,
                 cloudflare_email_routing, cloudflare_worker*, cloudflare_tunnel*, cloudflare_zero_trust_*,
                 cloudflare_access_*, aws_route53_*
  mail identity  aws_ses*  (identities, DKIM, MAIL FROM, configuration sets)
  certificates   aws_acm_*
  keys / trust   aws_kms_* (key, alias), aws_iam_openid_connect_provider, and by ADDRESS the CI OIDC roles
                 (module.iam_oidc.aws_iam_*, and *_role.chart_publish / ecr_push / infra_apply / infra_plan)

THE OVERRIDE is the PR label `allow-dns-destroy` (or the `allow_destructive` input of a manual dispatch). It is a
deliberate, visible, per-change decision made by a person after reading the list this script prints; the allowed
addresses are written to the job summary so the record survives the label being removed. It is NOT a permanent
suppression: the next plan is judged afresh.

FAIL-CLOSED: input that is not a plan (empty, `null`, `{}`, truncated) fails; it is never read as "no changes".
"""
from __future__ import annotations

import json
import os
import re
import sys

# Matching is by PREFIX, not an exact list, because the list is where this guard would rot: a provider adds
# cloudflare_r2_bucket_sippy, a new aws_ses_* resource appears, and an exact-type list silently stops protecting.
# The cost of a prefix is an occasional label on a harmless replace; the cost of a gap is the 2026-10-09 outage.
PROTECTED_PREFIXES = (
    # DNS and what serves it
    "cloudflare_record", "cloudflare_dns_record",
    "cloudflare_pages_",                 # project, domain
    "cloudflare_r2_",                    # bucket (+cors/lifecycle), custom domain, managed domain
    "cloudflare_zone",                   # zone, settings, dnssec, ...
    "cloudflare_ruleset", "cloudflare_turnstile_", "cloudflare_waf_", "cloudflare_custom_hostname",
    "cloudflare_certificate_pack", "cloudflare_origin_ca", "cloudflare_email_routing",
    "cloudflare_worker",                 # workers, routes, domains, KV
    "cloudflare_tunnel", "cloudflare_zero_trust_", "cloudflare_access_",
    "aws_route53_",
    # mail identity
    "aws_ses",                           # aws_ses_*, aws_sesv2_*
    # certificates
    "aws_acm_",
    # keys and the trust that lets CI act
    "aws_kms_",                          # key, alias, grant
    "aws_iam_openid_connect_provider",
)

# Some protected things are only recognisable by WHERE they are, because their type is the very common aws_iam_role:
# the CI OIDC roles (ecr-push, infra-apply, infra-plan) live in module.iam_oidc, and the chart-publish role is named by
# its address. Destroying one of these locks CI out of the account it needs in order to repair itself.
PROTECTED_ADDRESS_RE = (
    re.compile(r"^module\.iam_oidc\.aws_iam_"),
    re.compile(r"(^|\.)aws_iam_role(_policy(_attachment)?)?\.(chart_publish|ecr_push|infra_apply|infra_plan)(\[|$)"),
)

LABEL = "allow-dns-destroy"


def is_protected(rtype: str, address: str = "") -> bool:
    return rtype.startswith(PROTECTED_PREFIXES) or any(rx.search(address) for rx in PROTECTED_ADDRESS_RE)


def load(text: str) -> dict:
    try:
        doc = json.loads(text)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"destructive_guard: input is not JSON ({exc}). `tofu show -json <plan>` failed or was empty: "
                         "refusing to treat that as a plan with no changes.")
    if not isinstance(doc, dict) or "format_version" not in doc:
        raise SystemExit("destructive_guard: input is not a tofu plan (no format_version): refusing to treat it as a plan "
                         "with no changes.")
    return doc


def findings(doc: dict) -> list[tuple[str, str, str]]:
    out = []
    for rc in doc.get("resource_changes") or []:
        if rc.get("mode") != "managed":
            continue
        actions = (rc.get("change") or {}).get("actions") or []
        if "delete" not in actions or not is_protected(rc.get("type") or "", rc.get("address") or ""):
            continue
        verb = "REPLACE (destroy, then create)" if "create" in actions else "DESTROY"
        out.append((rc.get("address") or "<unknown>", rc.get("type") or "", verb))
    return out


def main(argv: list[str]) -> int:
    allow = "--allow" in argv
    doc = load(sys.stdin.read())
    bad = findings(doc)
    if not bad:
        print("destructive_guard: no DNS or identity resource is deleted or replaced.")
        return 0

    width = max(len(a) for a, _, _ in bad)
    lines = [f"  {a:<{width}}  {t}  {v}" for a, t, v in sorted(bad)]
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if allow:
        print(f"destructive_guard: {len(bad)} DNS/identity resource(s) will be deleted or replaced; ALLOWED by the "
              f"`{LABEL}` label / dispatch input:")
        print("\n".join(lines))
        if summary:
            with open(summary, "a", encoding="utf-8") as fh:
                fh.write(f"### DNS / identity destroy ALLOWED (`{LABEL}`)\n\n```\n" + "\n".join(lines) + "\n```\n")
        return 0

    print(f"::error title=DNS/identity resource would be destroyed::{len(bad)} resource(s); see the log")
    print(f"destructive_guard: REFUSED. This plan deletes or replaces {len(bad)} DNS/identity resource(s):")
    print("\n".join(lines))
    print(f"""
A replaced DNS record is an outage: the destroy happens first and the re-create can fail (2026-10-09: nine records,
three days). If this is intended, read the list above, then:
  * on a pull request: add the label `{LABEL}` and RE-RUN this job (the label is read live, not from the event);
  * on a push to main / manual dispatch: the merged PR must carry the label, or dispatch with allow_destructive=true.
If it is NOT intended (a provider bump, a lock-file change, an empty variable), something upstream is wrong: fix that.""")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("### REFUSED: DNS / identity resources would be destroyed\n\n```\n" + "\n".join(lines) + "\n```\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
