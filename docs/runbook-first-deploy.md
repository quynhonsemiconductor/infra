# Runbook — from here to qnsc-kb running on Kubernetes

Written 2026-09-16. Everything that can be built without a cluster is built; this
is the sequence that turns it into something running.

Read `implementation-plan.md` for *what each task is*. This is *what you do, in
what order, and what happens when you do it.*

**One rule throughout:** nothing in Part 1 or Part 2 changes how a single request
is served. If a step looks like it does, stop and re-read it.

**Use `tofu`, never `terraform`.** The estate is OpenTofu 1.12, and the two are
not interchangeable — `infra/live/bootstrap`'s provider cache uses
`assume_role_duration_seconds`, which OpenTofu has and HashiCorp Terraform does
not, so `terraform init` fails there with a message about an incompatible backend
configuration that sounds like corruption and is not.

---

# Part 1 — this week. Nothing touches AWS.

## 1.1 Send the residency email — for the LMS, not for the platform

```
DO       export data-residency-question.md to PDF, send it to a Vietnamese
         data-protection lawyer with the covering note
HAPPENS  a clock starts. Expect 2-6 weeks.
GATES    the LMS design (§17 step 4). NOT the clusters.
```

**CORRECTED 2026-09-16.** An earlier version of this runbook put this on the
critical path and blocked cluster creation on it. That was wrong.

**The data is already in Singapore.** rova and opshub already hold B2B personal
data there, and moving ECS → EKS in the same region changes the residency posture
by nothing: same region, same data, same transfers. The decision this question is
about was made years ago.

```
the platform migration   changes NOTHING about residency. Not blocked.
the LMS                  IS the new exposure — individual Vietnamese students at
                         scale — and it is not built yet, so it can still be
                         built differently at no cost
```

Still send it, and send it early: answer C would be expensive whenever it
arrives, and the LMS is the product that triggers it. But it stops standing
between you and a cluster.

## 1.2 Activate cost allocation tags

```
DO       cd infra/live/bootstrap && tofu apply
HAPPENS  nothing visible. AWS begins recording `product`, `env` and `size`.
KNOW IT  Cost Explorer offers them as a "Group by" dimension (24-48h later)
IF NOT   §12b's contingency plan has no data. Activation is NOT RETROACTIVE:
         AWS records a tag from the day it is activated and says nothing about
         the days before.
```

**CORRECTED 2026-09-16** — this was written as a Billing console click. It is an
API (`aws_ce_cost_allocation_tag`), so it belongs in
`infra/live/bootstrap/cost-tags.tf` like everything else. A console click nobody
recorded is exactly what §12b cannot afford to depend on.

This is the item with the most permanent cost of delay and the least effort.

## 1.3 Start the measurement

```
DO       aws login, then
           ./infra/scripts/measure_ecs_usage.py            # everything
HAPPENS  a 14-day window begins filling. Run it again in two weeks.
KNOW IT  it prints a table for rova prod and all three dev environments
IF NOT   §15's node sizing stays a guess and §14's Auto Mode trade cannot be
         re-decided. It is also the input to task 2.9.
```

**What can and cannot be measured, and it is not symmetric:**

```
rova prod              the ONLY production workload in the estate. Measure it.
rova · opshub · kb dev all three run. Measure them — qnsc-kb dev DOMINATES,
                       allocated 6 vCPU / 16 GiB, more than half of dev
kb prod                no state file. NO DATA is the correct answer
opshub prod            never launched. Same
```

So `--product kb` was the wrong first call: kb dominates *dev*, but rova is the
only source of *production* numbers. Run it without a filter and take both.

kb prod and opshub prod get measured after they launch — which is after they
migrate, so their §15 figures stay estimates until then and should be reported as
estimates rather than treated as zero.

---

# Part 2 — next week. Safe changes to the estate you already run.

Each of these is a PR with a reviewed `tofu plan`. **None creates or destroys a
resource** except 2.4, which is flagged.

## 2.1 `prevent_destroy` on every data resource

```
DO       add lifecycle { prevent_destroy = true } to every aws_db_instance,
         aws_elasticache_* and aws_secretsmanager_secret in
         rova/infra/live, opshub/infra/live, qnsc-kb-backend/infra/live
HAPPENS  nothing. It is a state-only attribute.
KNOW IT  `tofu plan` reports "no changes" on all six stacks
IF NOT   §17b's trap stays armed: one state owns both the database and the ECS
         services, so a destroy aimed at ECS takes the database. 2026-09-14
         already cost twelve minutes of downtime learning that.
```

Do this first in Part 2. It is the insurance for everything after it.

## 2.2 ECR retention — preview, THEN apply

```
DO       aws ecr start-lifecycle-policy-preview --repository-name rova-api \
           --lifecycle-policy-text "$(...)"
         aws ecr get-lifecycle-policy-preview --repository-name rova-api
HAPPENS  a dry run. Nothing is deleted.
KNOW IT  the preview output is attached to the PR, and it expires no release you
         would want to roll back to
THEN     apply release_retention_days = 180 (already written in tf-modules)
IF WRONG a time rule can delete what a count rule was keeping, and at a low
         promotion rate thirty releases may span more than 180 days. RAISE the
         number; do not lower it to match what the count rule happened to keep.
```

## 2.3 Stop publishing `:latest`, then make tags immutable

```
DO   (a) remove every :latest push from CI
     (b) THEN set image_tag_mutability = "IMMUTABLE" on all four ECR repos
HAPPENS  (a) nothing. (b) a second push of an existing tag starts failing.
KNOW IT  a deliberate re-push of an existing tag is rejected
ORDER    (b) BEFORE (a) BREAKS THE PIPELINE — IMMUTABLE rejects the second
         :latest push, so the next build fails.
```

`qnsc-kb-backend/infra/live/prod/main.tf:104` records where this already went
wrong: a task definition reset to *"whatever `:latest` points at — which is a
develop build."*

## 2.4 Subnet resize — the one with real risk

```
DO       resize private subnets /24 → /20 in runtime-dev, then runtime-prod
         enable prefix delegation on the VPC CNI
HAPPENS  subnets are RECREATED. Existing ECS tasks keep their IPs; new
         placements use the new range.
KNOW IT  `aws ec2 describe-subnets` shows /20, and existing services stay healthy
DO FIRST dev. Watch for a day. Then prod, in the Mon 04:30-06:00 UTC window.
IF NOT   §15c failure #2 — pods stuck in ContainerCreating with no obvious cause,
         at roughly fifteen services. The space is free today and requires
         recreating subnets under load later.
```

This is the only Part 2 step that touches live networking. It is also the only one
that cannot be done after the cluster exists.

---

# Part 3 — cluster bring-up

No gate. Correction 1.1 removed the one that used to be here: the residency
answer governs the LMS, not the platform, because the data is already in
Singapore and this migration does not move it.

What DOES gate Part 3 is Part 2 — specifically **2.4, the subnet resize**, which
cannot be done after a cluster exists.

## 3.1 Write the secret values

```
DO       put real values into Secrets Manager, out of band:
           qnsc/<env>/platform/grafana/*          Alloy's one credential (§8)
           qnsc/<env>/platform/cloudflared-token  the tunnel
           qnsc/<env>/platform/postgres-admin     product-profile's provider
           qnsc/<env>/kb/app/*                    database-url, redis-url, …
           qnsc/<env>/kb/migrator/*               the DDL credential
           qnsc/<env>/kb/keda/*                   Grafana Cloud read, for the
                                                  request-rate trigger
HAPPENS  nothing. ESO reads them later.
KNOW IT  `aws secretsmanager get-secret-value` returns each one
IF NOT   ESO syncs empty secrets, pods start, and every product looks broken for
         a reason three layers away.
```

These never enter OpenTofu state or git. The module creates the **containers**;
you write the **values** (§8).

## 3.2 Verify the versions

```
DO       check every line of gitops/versions.yaml against
           helm search repo <chart> --versions
         and the EKS supported-versions page
HAPPENS  nothing yet.
KNOW IT  each pinned version exists and EKS still supports the Kubernetes minor
IF NOT   a chart install fails with a confusing error, or you install a version
         whose CRDs the cluster rejects. Those numbers were written 2026-09-15
         from memory and releases move.
```

## 3.3 Wire the SSO role ARNs

```
DO       find the PROVISIONED Identity Center role ARNs —
           aws iam list-roles | grep AWSReservedSSO
         and pass the four into cluster-{dev,prod} as `sso_roles`
HAPPENS  nothing yet.
KNOW IT  `tofu plan` on cluster-prod resolves without an unknown variable
WHY      permission set ARNs are NOT the role ARNs an access entry needs. This is
         the one thing §7c cannot derive, because Identity Center mangles the
         name with a random suffix.
```

## 3.4 Apply the stacks, in this order

```
1  organization      the permission sets 3.3 reads
2  runtime-prod      already applied; confirm the /20 from 2.4
3  data-prod         qnsc-shared-prod, the cache
4  cluster-prod      FIRST of the two — it outputs argocd_role_arn
5  runtime-dev · data-dev
6  cluster-dev       consumes argocd_role_arn

HAPPENS  ~$146/month starts. Two clusters exist and run nothing.
KNOW IT  `aws eks describe-cluster` returns ACTIVE for both
```

**This is §17b's worst place to stop.** Two clusters delivering nothing. Keep
going to at least 4.3.

## 3.5 Bootstrap the platform

```
DO       follow gitops/platform/argocd/bootstrap.md exactly. The ordering is not
         arbitrary and each line says why.
HAPPENS  namespaces, policy, ESO, KEDA, Gateway, cloudflared, Alloy, ArgoCD.
         The last manual command is `kubectl apply -f apps/root.yaml`.
KNOW IT  argocd app list shows root Synced, and the ApplicationSets have
         generated Applications
THEN     DELETE THE DEV CLUSTER AND REBUILD IT FROM THIS RUNBOOK. TIME IT.
         WRITE THE NUMBER INTO §13.
```

That last line is §13's demand, and until it happens the RTO figures there are
estimates. It is also the only way to find what is not in git.

---

# Part 4 — qnsc-kb dev, the first workload

## 4.1 Apply the product stack

```
DO       cd infra/live/kb/dev && tofu apply
         THEN: tofu output -raw role_settings_sql | psql "$ADMIN_URL"
HAPPENS  a database, two roles, four secret containers, three IRSA roles, an
         SQS queue and its DLQ.
KNOW IT  ci/scripts/platform_conformance.py --root . passes with kb/dev PAIRED
DO NOT   skip the SQL. Until it runs, nothing bounds a noisy neighbour and the
         migrator carries the 30s application timeout rather than 600s.
```

## 4.2 Build and deploy

```
DO       merge anything to qnsc-kb-backend's main with the k8s-deploy workflow wired
HAPPENS  images build as sha-<commit>, CI edits gitops/values/kb/tags.dev.yaml,
         ArgoCD syncs, the migrator Job runs as a PreSync hook, pods start.
KNOW IT  kb.dev.qnsc.vn answers, and the migrator Job shows Completed
WATCH    the api pod's startupProbe — the e5 ONNX session takes tens of seconds.
         If it is being killed mid-load, the startupProbe is wrong, not the app.
```

## 4.3 Soak for one week

§17b's checklist, and *all* of it:

```
error rate        at or below the ECS baseline for the same window
p99 latency       within the tunnel's 5-15 ms overhead of baseline
restarts          no unexplained pod restarts
SLO burn rate     flat
cron coverage     every scheduled job has run at least once
deploy            one release shipped end to end through the new path
rollback          one rollback REHEARSED, not assumed
```

**This is a good place to stop indefinitely** if a product deadline lands.
qnsc-kb dev on Kubernetes, everything else on ECS. Two platforms, tolerable.

---

# What happens next

`§17`: qnsc-kb prod → **LMS** → opshub → **rova last, two-week soak**.

**The LMS is where 1.1's answer lands**, and it is a real gate on that step:

```
ANSWER A   Singapore is fine, with a filing   →  build the LMS on the platform
ANSWER B   LMS student data stays in Vietnam  →  the LMS does NOT go on the
                                                 shared platform. §12b prices it:
                                                 a second deployment target, a
                                                 second set of procedures, and a
                                                 network path between them
ANSWER C   all Vietnamese personal data       →  STOP EVERYTHING. AWS has no
                                                 Vietnam region, so this is a
                                                 different provider and most of
                                                 the design is re-evaluated
```

Answer C is unlikely and would be expensive whenever it arrived — which is why
1.1 is still sent in week one even though it no longer blocks a cluster.

Then §17b's retirement: scale ECS to zero, delete only the ECS **blocks** from
each stack's configuration, and never `tofu destroy` — one state owns both the
database and the ECS services.

# The abort criterion, agreed now

```
stop and re-evaluate if    Part 3 exceeds 10 weeks
                           any product migration exceeds 2x its estimate
                           two consecutive products fail their soak
```

Stopping is not failure. It means something in the design was wrong, and the cost
of finding out is capped.
