#!/usr/bin/env python3
"""Report cost-bearing AWS resources that OpenTofu does not manage.

WHY THIS EXISTS. On 2026-09-09 at 16:57 the ROOT user created `database-1`: a
db.m8i.4xlarge SQL Server ENTERPRISE instance, 500 GB gp3, in the DEFAULT VPC, with no
tags. It ran for three days at roughly $110/day and had ZERO database connections for its
entire life. Month-to-date spend reached $402 against a $500 budget.

Nothing reported it, and nothing could have:

  * `tofu plan` is blind to it. Plan reports on resources IN STATE; a resource created
    outside OpenTofu has no address to diff against. Drift detection does not cover this
    class at all.
  * The account budget had no notifications and the cost-anomaly monitor had no
    subscriber, both because `var.alert_emails` was `[]` (fixed 2026-09-12).
  * No alarm topic in the account had any subscription.

So this script closes the one gap that neither drift detection nor cost alerting can:
resources that exist and cost money while being absent from state.

THE INVARIANT IT RELIES ON. Every `provider "aws"` block in this org sets `default_tags`
including `ManagedBy = "opentofu"`. So "carries no ManagedBy tag" is a precise synonym for
"not managed by OpenTofu". That invariant is free and was never queried until now.

WHY NOT THE RESOURCE GROUPS TAGGING API. Because it does not work for this. It was tried
first and rejected on evidence — `GetResources` with `--resource-type-filters rds:db`
returned the five tagged instances and OMITTED `database-1`, because that API covers
"tagged or previously tagged" resources and this one had never been tagged. A control built
on it would have missed the single largest cost event on the account. Hence the per-service
enumeration below, which asks each service directly and therefore sees everything.

A REPORT THAT FAILS THE JOB, unlike scripts/pin_drift.py in the `ci` repo. That one prints
a table and exits 0 because holding a version back is a legitimate decision. Here there is
no legitimate reason for an untracked cost-bearing resource to persist unexamined, and a
scheduled workflow has nothing to gate — so a non-zero exit is the notification: GitHub
emails the actor when a scheduled run fails. Adopt the resource into OpenTofu, delete it, or
add it to ALLOWLIST with a reason.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

REGION = os.environ.get("AWS_REGION", "ap-southeast-1")

# The tag every OpenTofu-managed resource carries via provider default_tags.
MANAGED_TAG = "ManagedBy"

# Resources that are deliberately NOT in OpenTofu. Each entry needs a reason, so that an
# allowlist cannot quietly become a place where findings go to be forgotten.
#
# Keyed by the identifier this script prints, so a finding can be pasted straight in.
ALLOWLIST: dict[str, str] = {
    # TrueIDC / Ascend partner proof-of-concept, created by root 2026-09-09. Billed to the
    # payer account 033086823579 under consolidated billing, not to QNSC. Deliberately left
    # outside OpenTofu because it is not ours to manage; it is listed here so it stops
    # appearing as an unexplained finding. REVISIT when the PoC ends.
    "arn:aws:rds:ap-southeast-1:608983206583:db:database-1": "TrueIDC PoC, partner-owned, payer-billed",
}


class ScanFailed(Exception):
    """A service could not be enumerated, as distinct from being enumerated and found clean.

    This exists because the two used to be indistinguishable and the consequence was a FALSE
    GREEN. `aws()` returned None on failure, every scanner turned that into an empty list,
    and main() printed "clean" for each one and exited 0. Measured 2026-09-14 with a bogus
    profile: the script reported "No unmanaged resources. Everything cost-bearing is in
    OpenTofu" having read nothing at all.

    A scheduled run whose role had expired would therefore report the account clean, every
    day, indefinitely — the exact failure this scanner was written to prevent, reproduced
    inside the scanner. An unreadable service must be louder than an empty one, not quieter.
    """


def aws(*args: str) -> object:
    """Run an AWS CLI command and parse its JSON. The CLI is preinstalled on GitHub
    runners, so this script needs no pip install — the same dependency-free choice
    scripts/pin_drift.py makes.

    Raises ScanFailed rather than returning None; see that class for why."""
    cmd = ["aws", *args, "--region", REGION, "--output", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise ScanFailed(f"`{' '.join(cmd[:3])}…` failed: {result.stderr.strip()[:200]}")
    return json.loads(result.stdout or "null")


def tag_names(tags: object) -> set[str]:
    """Normalise the three tag shapes AWS returns: [{Key,Value}], [{key,value}], {k: v}."""
    if isinstance(tags, dict):
        return set(tags.keys())
    if isinstance(tags, list):
        names = set()
        for tag in tags:
            if isinstance(tag, dict):
                key = tag.get("Key", tag.get("key"))
                if key:
                    names.add(key)
        return names
    return set()


def unmanaged(identifier: str, tags: object) -> bool:
    return MANAGED_TAG not in tag_names(tags) and identifier not in ALLOWLIST


# ── Scanners ─────────────────────────────────────────────────────────────────
# Each returns a list of (identifier, human_description) for UNMANAGED resources.
# Ordered roughly by how expensive an accident in that service tends to be.


def scan_rds_instances() -> list[tuple[str, str]]:
    data = aws("rds", "describe-db-instances") or {}
    found = []
    for db in data.get("DBInstances", []):
        arn = db["DBInstanceArn"]
        if unmanaged(arn, db.get("TagList")):
            found.append(
                (
                    arn,
                    f"{db['DBInstanceIdentifier']} · {db['DBInstanceClass']} · "
                    f"{db.get('Engine')} · {db.get('AllocatedStorage')}GB · {db['DBInstanceStatus']}",
                )
            )
    return found


def scan_rds_clusters() -> list[tuple[str, str]]:
    data = aws("rds", "describe-db-clusters") or {}
    found = []
    for c in data.get("DBClusters", []):
        arn = c["DBClusterArn"]
        if unmanaged(arn, c.get("TagList")):
            found.append((arn, f"{c['DBClusterIdentifier']} · {c.get('Engine')} · aurora/cluster"))
    return found


def scan_elasticache() -> list[tuple[str, str]]:
    """ElastiCache does not return tags from describe-cache-clusters, so each node needs a
    second call. Small N, so the extra calls are cheaper than the alternative of missing a
    ~$15/mo node — which is exactly what happened with opshub-develop-valkey-001."""
    data = aws("elasticache", "describe-cache-clusters") or {}
    found = []
    for node in data.get("CacheClusters", []):
        arn = node.get("ARN")
        if not arn:
            continue
        tags = aws("elasticache", "list-tags-for-resource", "--resource-name", arn) or {}
        if unmanaged(arn, tags.get("TagList")):
            found.append(
                (arn, f"{node['CacheClusterId']} · {node['CacheNodeType']} · {node.get('Engine')}")
            )
    return found


def scan_ec2_instances() -> list[tuple[str, str]]:
    data = aws("ec2", "describe-instances") or {}
    found = []
    for reservation in data.get("Reservations", []):
        for inst in reservation.get("Instances", []):
            state = inst.get("State", {}).get("Name")
            if state in ("terminated", "shutting-down"):
                continue
            iid = inst["InstanceId"]
            if unmanaged(iid, inst.get("Tags")):
                found.append((iid, f"{inst.get('InstanceType')} · {state}"))
    return found


def scan_ebs_volumes() -> list[tuple[str, str]]:
    """Detached volumes are the classic silent cost: deleting an instance by hand leaves the
    volume billing indefinitely."""
    data = aws("ec2", "describe-volumes") or {}
    found = []
    for vol in data.get("Volumes", []):
        vid = vol["VolumeId"]
        if unmanaged(vid, vol.get("Tags")):
            detached = " · DETACHED" if vol.get("State") == "available" else ""
            found.append((vid, f"{vol.get('Size')}GB {vol.get('VolumeType')}{detached}"))
    return found


def scan_eips() -> list[tuple[str, str]]:
    """An unassociated Elastic IP bills whether or not anything uses it."""
    data = aws("ec2", "describe-addresses") or {}
    found = []
    for addr in data.get("Addresses", []):
        ident = addr.get("AllocationId") or addr.get("PublicIp")
        if unmanaged(ident, addr.get("Tags")):
            idle = " · UNASSOCIATED" if not addr.get("AssociationId") else ""
            found.append((ident, f"{addr.get('PublicIp')}{idle}"))
    return found


def scan_nat_gateways() -> list[tuple[str, str]]:
    """~$33/mo each. This org deliberately runs fck-nat instances instead, so any NAT
    gateway at all is worth a second look."""
    data = aws("ec2", "describe-nat-gateways") or {}
    found = []
    for nat in data.get("NatGateways", []):
        if nat.get("State") in ("deleted", "deleting"):
            continue
        nid = nat["NatGatewayId"]
        if unmanaged(nid, nat.get("Tags")):
            found.append((nid, f"NAT gateway · {nat.get('State')} · vpc {nat.get('VpcId')}"))
    return found


def scan_load_balancers() -> list[tuple[str, str]]:
    data = aws("elbv2", "describe-load-balancers") or {}
    lbs = data.get("LoadBalancers", [])
    if not lbs:
        return []
    found = []
    for lb in lbs:
        arn = lb["LoadBalancerArn"]
        tag_data = aws("elbv2", "describe-tags", "--resource-arns", arn) or {}
        descriptions = tag_data.get("TagDescriptions") or [{}]
        if unmanaged(arn, descriptions[0].get("Tags")):
            found.append((arn, f"{lb['LoadBalancerName']} · {lb.get('Type')} · {lb.get('Scheme')}"))
    return found


SCANNERS = [
    ("RDS instances", scan_rds_instances),
    ("RDS clusters", scan_rds_clusters),
    ("ElastiCache nodes", scan_elasticache),
    ("EC2 instances", scan_ec2_instances),
    ("EBS volumes", scan_ebs_volumes),
    ("Elastic IPs", scan_eips),
    ("NAT gateways", scan_nat_gateways),
    ("Load balancers", scan_load_balancers),
]


def main() -> int:
    lines: list[str] = [
        "## Unmanaged AWS resources",
        "",
        f"Region `{REGION}` · resources with no `{MANAGED_TAG}` tag, i.e. absent from OpenTofu.",
        "",
    ]
    total = 0

    unreadable: list[tuple[str, str]] = []

    for label, scanner in SCANNERS:
        try:
            findings = scanner()
        except ScanFailed as why:
            # NOT counted as clean. See ScanFailed for the false green this prevents.
            unreadable.append((label, str(why)))
            lines.append(f"- **{label}** — COULD NOT SCAN: {why}")
            continue
        if not findings:
            lines.append(f"- **{label}** — clean")
            continue
        total += len(findings)
        lines.append("")
        lines.append(f"### {label} — {len(findings)} unmanaged")
        lines.append("")
        lines.append("| Identifier | Detail |")
        lines.append("| :--- | :--- |")
        for ident, detail in findings:
            lines.append(f"| `{ident}` | {detail} |")
        lines.append("")

    lines.append("")
    if total:
        lines.append(
            f"**{total} unmanaged resource(s).** For each: adopt it into OpenTofu with an "
            "`import` block, delete it, or add it to `ALLOWLIST` in this script with a reason."
        )
    else:
        lines.append("**No unmanaged resources.** Everything cost-bearing is in OpenTofu.")

    if ALLOWLIST:
        lines.append("")
        lines.append("<details><summary>Allowlisted (deliberately outside OpenTofu)</summary>")
        lines.append("")
        for ident, reason in ALLOWLIST.items():
            lines.append(f"- `{ident}` — {reason}")
        lines.append("")
        lines.append("</details>")

    report = "\n".join(lines)
    print(report)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(report + "\n")

    if unreadable:
        lines.append("")
        lines.append(
            f"**{len(unreadable)} service(s) could not be scanned.** That is not a clean "
            "result and is deliberately failed: a scan that did not run cannot vouch for "
            "the account. Usually an expired or missing role."
        )

    # Non-zero so a scheduled run turns red and GitHub notifies. See the module docstring.
    # Unreadable services fail too — reporting clean on data never read is the one outcome
    # worse than reporting a finding.
    return 1 if (total or unreadable) else 0


if __name__ == "__main__":
    sys.exit(main())
