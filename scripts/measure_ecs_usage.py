#!/usr/bin/env python3
"""Measure what ECS services actually USE, so Kubernetes requests are sized from
evidence rather than from the ceilings someone once picked.

WHY THIS EXISTS. `kubernetes-platform-design.md` §15d:

    "Every request figure in §15 is an ECS *allocation*, and allocation is
     typically two to three times measured p50."

That was a tolerable weakness while the IC lab was a hard requirement Kubernetes
alone could meet. It is not tolerable now: the lab was withdrawn, cost re-priced
to a wash against Fargate, and §15 is the only quantitative leg the platform
decision still stands on. These numbers decide node sizing, the Auto Mode trade
(§14), and whether §15 means anything.

Run it for two weeks before sizing anything. qnsc-kb first — it is roughly half of
both environments, so its real numbers move the total more than everything else
combined.

    ./measure_ecs_usage.py                 # everything, 14 days
    ./measure_ecs_usage.py --product kb    # the one that matters most
    ./measure_ecs_usage.py --days 30 --json

WHAT IT CAN AND CANNOT SEE.

`AWS/ECS` CPUUtilization and MemoryUtilization are PERCENTAGES OF THE ALLOCATED
task size, not absolute values. Absolute figures live in Container Insights — and
rova and opshub both set `container_insights = "disabled"`
(rova/infra/live/prod/main.tf:235, opshub/infra/live/prod/main.tf:122), because
"enhanced" once billed 606 custom metric-months at $0.07 each.

So this script converts: absolute = percentage x allocation. The allocations below
are transcribed from the live OpenTofu with file:line, and MUST be re-checked when
that changes — a stale table here produces confident wrong numbers, which is worse
than no numbers.

A service with `min_count = 0` that has never run reports NO DATA rather than
zero. qnsc-kb production has no state file and opshub production never launched;
their figures stay estimates until they run, and saying so is the point.
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from datetime import datetime, timedelta, timezone

# ── Allocations, transcribed from the live OpenTofu ──────────────────────────
# cpu is in ECS units (1024 = 1 vCPU); memory in MiB.
# RE-CHECK THESE when a task definition changes. The conversion below is only as
# honest as this table.
ALLOCATIONS = {
    # product, env, service:  (cpu_units, memory_mib, source)
    ("rova", "prod", "api"): (256, 1024, "rova/infra/live/prod/main.tf:476"),
    ("rova", "prod", "worker"): (256, 512, "rova/infra/live/prod/main.tf:520"),
    ("rova", "develop", "api"): (512, 1024, "rova/infra/live/develop/main.tf:503"),
    ("rova", "develop", "worker"): (256, 512, "rova/infra/live/develop/main.tf:513"),
    ("opshub", "prod", "api"): (1024, 2048, "opshub/infra/live/prod/main.tf:194"),
    ("opshub", "prod", "worker"): (512, 1024, "opshub/infra/live/prod/main.tf:205"),
    ("opshub", "develop", "api"): (512, 1024, "opshub/infra/live/develop/main.tf:249"),
    ("opshub", "develop", "worker"): (256, 512, "opshub/infra/live/develop/main.tf:258"),
    ("kb", "prod", "api"): (1024, 6144, "qnsc-kb-backend/infra/live/prod/main.tf:136"),
    ("kb", "prod", "worker"): (2048, 6144, "qnsc-kb-backend/infra/live/prod/main.tf:152"),
    ("kb", "develop", "api"): (2048, 8192, "qnsc-kb-backend/infra/live/develop/main.tf:104"),
    ("kb", "develop", "worker"): (4096, 8192, "qnsc-kb-backend/infra/live/develop/main.tf:135"),
}

# §7c renames the qnsc-kb slug to `kb`. Until those ECR repositories and
# clusters are recreated, AWS still calls it qnsc-kb — so the measurement has
# to ask for the name that exists today, not the one the design wants.
AWS_SLUG = {"kb": "qnsc-kb"}

REGION = "ap-southeast-1"
PERIOD = 3600  # one hour. 14 days = 336 datapoints per metric, well inside limits.


def aws(*args: str) -> dict:
    out = subprocess.run(
        ["aws", "--region", REGION, *args, "--output", "json"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        print(f"aws {' '.join(args[:2])} failed: {out.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return json.loads(out.stdout or "{}")


def fetch(cluster: str, service: str, metric: str, days: int) -> list[dict]:
    """Hourly p50, p95 and Maximum for one metric.

    Percentiles are computed WITHIN each hour; the aggregation across hours
    happens in summarise(). That is deliberate — an hourly p95 answers "how bad is
    a normal busy hour", which is the question a memory limit needs. A percentile
    over the whole fortnight would be dominated by idle nights.
    """
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=days)
    queries = [
        {
            "Id": f"m{i}",
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/ECS",
                    "MetricName": metric,
                    "Dimensions": [
                        {"Name": "ClusterName", "Value": cluster},
                        {"Name": "ServiceName", "Value": service},
                    ],
                },
                "Period": PERIOD,
                "Stat": stat,
            },
        }
        for i, stat in enumerate(["p50", "p95", "Maximum"])
    ]
    res = aws(
        "cloudwatch", "get-metric-data",
        "--metric-data-queries", json.dumps(queries),
        "--start-time", start.isoformat(),
        "--end-time", end.isoformat(),
    )
    return res.get("MetricDataResults", [])


def summarise(results: list[dict]) -> dict | None:
    by_id = {r["Id"]: r.get("Values", []) for r in results}
    p50, p95, mx = by_id.get("m0", []), by_id.get("m1", []), by_id.get("m2", [])
    if not p50:
        return None
    return {
        # Median of hourly p50s: what a typical hour looks like. This is the
        # REQUEST, because requests are the bin-packing unit and therefore the bill.
        "typical": statistics.median(p50),
        # The 95th percentile of hourly p95s: a bad-but-normal hour. This is the
        # MEMORY LIMIT. Memory is not compressible, so this number decides whether
        # a pod is OOMKilled on a busy afternoon.
        "high": statistics.quantiles(p95, n=20)[-1] if len(p95) > 1 else p95[0],
        "peak": max(mx) if mx else 0.0,
        "hours": len(p50),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--product", help="rova | opshub | kb")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    rows, missing = [], []
    for (product, env, svc), (cpu_alloc, mem_alloc, src) in sorted(ALLOCATIONS.items()):
        if args.product and product != args.product:
            continue
        # rova/infra/modules/stack/main.tf:19  name = "${product}-${env_slug}"
        # tf-modules/modules/ecs-service/main.tf:2  full_name = "${cluster_name}-${service_name}"
        cluster = f"{AWS_SLUG.get(product, product)}-{env}"
        service = f"{cluster}-{svc}"

        cpu = summarise(fetch(cluster, service, "CPUUtilization", args.days))
        mem = summarise(fetch(cluster, service, "MemoryUtilization", args.days))
        if not cpu or not mem:
            missing.append((product, env, svc))
            continue

        rows.append({
            "product": product, "env": env, "service": svc, "source": src, "hours": cpu["hours"],
            "cpu_alloc_m": round(cpu_alloc / 1024 * 1000),
            "cpu_typical_m": round(cpu["typical"] / 100 * cpu_alloc / 1024 * 1000),
            "cpu_peak_m": round(cpu["peak"] / 100 * cpu_alloc / 1024 * 1000),
            "mem_alloc_mi": mem_alloc,
            "mem_typical_mi": round(mem["typical"] / 100 * mem_alloc),
            "mem_high_mi": round(mem["high"] / 100 * mem_alloc),
            "mem_peak_mi": round(mem["peak"] / 100 * mem_alloc),
        })

    if args.json:
        print(json.dumps({"measured": rows, "no_data": missing}, indent=2))
        return 0

    if rows:
        print(f"\n  {args.days} days, ap-southeast-1. Absolute values derived from "
              f"percentage x allocation — Container Insights is disabled on rova and opshub.\n")
        print(f"  {'service':<22} {'cpu alloc':>9} {'→ request':>10} {'mem alloc':>10} "
              f"{'→ request':>10} {'→ limit':>9} {'peak':>8}")
        print("  " + "-" * 84)
        for r in rows:
            print(f"  {r['product']+'/'+r['env'][:4]+'/'+r['service']:<22} "
                  f"{str(r['cpu_alloc_m'])+'m':>9} {str(r['cpu_typical_m'])+'m':>10} "
                  f"{str(r['mem_alloc_mi'])+'Mi':>10} {str(r['mem_typical_mi'])+'Mi':>10} "
                  f"{str(r['mem_high_mi'])+'Mi':>9} {str(r['mem_peak_mi'])+'Mi':>8}")

        cpu_alloc = sum(r["cpu_alloc_m"] for r in rows)
        cpu_used = sum(r["cpu_typical_m"] for r in rows)
        mem_alloc = sum(r["mem_alloc_mi"] for r in rows)
        mem_used = sum(r["mem_typical_mi"] for r in rows)
        print(f"\n  allocated   {cpu_alloc}m cpu   {mem_alloc}Mi memory")
        print(f"  typical     {cpu_used}m cpu   {mem_used}Mi memory"
              f"   ({cpu_alloc/max(cpu_used,1):.1f}x cpu, {mem_alloc/max(mem_used,1):.1f}x memory over-allocated)")
        print("\n  → request = typical. limit = the 'limit' column, MEMORY ONLY.")
        print("    The chart renders no CPU limit at all: CFS quota throttles on")
        print("    100 ms bursts rather than averages, so an IO-bound service is")
        print("    throttled at 20% average CPU and it presents as latency with no")
        print("    OOMKill, no restart and no alarm (§15d).")

    if missing:
        print("\n  NO DATA — these have not run in the window, so their §15 figures")
        print("  remain estimates. Say so rather than treating silence as zero:")
        for product, env, svc in missing:
            print(f"    {product}/{env}/{svc}")
        print("\n  qnsc-kb production has no state file and opshub production never")
        print("  launched (§17), so absence here is expected, not a failure.")

    if not rows and not missing:
        print("nothing matched — check --product")
    return 0


if __name__ == "__main__":
    sys.exit(main())
