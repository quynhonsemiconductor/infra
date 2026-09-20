# Runbook — from here to rova running on Kubernetes

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
DO       add the /20 CLUSTER subnets in runtime-dev, then runtime-prod.
         `cluster_subnet_cidrs` is already set in both — this is an apply.
         NOTHING to do about prefix delegation. See below.
HAPPENS  three new subnets per VPC, associated with the EXISTING private route
         tables. No existing subnet is touched. No ECS task is touched.
KNOW IT  `aws ec2 describe-subnets --filters Name=tag:Tier,Values=cluster` returns
         three /20s per VPC, and the /24 private subnets are still there
DO FIRST dev. Then prod — and it no longer needs a maintenance window, because
         nothing is recreated.
IF NOT   §15c failure #2 — pods stuck in ContainerCreating with no obvious cause,
         at roughly fifteen services.
```

**THIS STEP USED TO BE WRONG, AND WRONG IN THE DIRECTION THAT COSTS AN OUTAGE.**
It said "resize private subnets /24 → /20" and "subnets are RECREATED. Existing
ECS tasks keep their IPs". They do not. AWS has **no subnet-resize operation**;
`cidr_block` on `aws_subnet` forces replacement, and a subnet with attached ENIs
cannot be deleted — so the apply fails part-way, after whatever it managed to do
first, against the VPC running production. Corrected 2026-09-19.

What happens instead is additive: a fourth tier, `Tier = cluster`, routed through
the private route tables so it inherits NAT egress and the free S3 gateway
endpoint. The ECS /24s keep every task where it is, which is also what keeps
§17b's cutover reversible.

**Prefix delegation needs nothing.** EKS Auto Mode already defaults to /28 prefix
delegation, and AWS states that VPC CNI configuration options do not apply to Auto
Mode. There is no addon to configure and adding one would be inert. That default
is also why a /24 was too small: Auto Mode reserves 16 addresses per node up
front, so a /24 is about fifteen nodes per AZ, shared with ECS.

This is no longer the only Part 2 step that touches live networking — it is now
the only one that **adds** to it. It is still the one that cannot be done
comfortably after the cluster exists.

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

## 3.3 Confirm security-baseline exports the human roles

**Nothing to wire — this step is a check.** `sso_roles` was a variable and is not
any more; cluster-{dev,prod} read the ARNs from `security-baseline`'s state.

```
DO       cd infra/live/security-baseline && tofu output | grep role_arn
KNOW IT  three outputs exist —
           human_admin_role_arn       -> platform_admin  (cluster-admin)
           human_developer_role_arn   -> developer       (edit on dev, VIEW on prod)
           prod_breakglass_role_arn   -> break_glass     (prod only)
HAPPENS  nothing.
WHY      THREE, not four. An earlier version of this runbook said to find four
         Identity Center role ARNs and pass them in, and named `organization` as
         their source. Both were wrong: `organization` exports PERMISSION SET
         arns, which are a different object from the `AWSReservedSSO_*` roles an
         access entry takes, and the estate has no `read_only` role — qnsc-developer
         carries ReadOnlyAccess, which is why its entry is VIEW on production.
         A fourth field pointing at the same ARN is not harmless either:
         `aws_eks_access_entry` is keyed on principal_arn, so it is a duplicate
         resource error.

         `alert_topic_arn` came from the same place and went the same way —
         cluster-prod reads security-baseline's `security_alerts_topic_arn`.
```

**If those outputs are missing, security-baseline has not been applied.** Apply it
before cluster-prod, which reads its state for both the roles and the alert topic.

## 3.4 Apply the stacks, in this order

```
0  bootstrap         RE-APPLY. It now also creates the chart's OCI repository,
                     `charts/qnsc-service` (task 1.8). Nothing else in this list
                     matters without it: every ArgoCD Application pins that chart
                     as its source, and ECR does not create a repository on push.
1  security-baseline the three human role ARNs and the alert topic 3.3 checks.
                     NOT `organization` — an earlier version of this list said
                     that, and it exports permission sets, not role ARNs.
                     (`organization` cannot plan today anyway: AccessDenied on
                     sso:DescribePermissionSet and organizations:ListAccounts.
                     It is in NOT_PLANNABLE with the diagnosis.)
2  runtime-prod      NOT "confirm". It ADDS three /20 cluster subnets — a real
                     change to an applied production stack. Read the plan.
3  data-prod         qnsc-shared-prod, the cache
4  cluster-prod      FIRST of the two — it outputs argocd_role_arn, and now also
                     qnsc-prod-argocd-ecr for the chart-token refresher
5  runtime-dev · data-dev
6  cluster-dev       consumes argocd_role_arn. Also exports the API server CA,
                     which ArgoCD's cluster registration needs and which was
                     missing until 2026-09-19

HAPPENS  ~$146/month starts. Two clusters exist and run nothing.
KNOW IT  `aws eks describe-cluster` returns ACTIVE for both
```

**This is §17b's worst place to stop.** Two clusters delivering nothing. Keep
going to at least 4.3.

## 3.5 Bootstrap the platform

```
DO       follow gitops/platform/README.md's apply order exactly. The ordering is
         not arbitrary and each step says why. Four things in it did not exist
         before 2026-09-19 and every one of them is load-bearing:

         0  platform/compute/     BEFORE ARGOCD. Auto Mode's built-in
                                  general-purpose pool is amd64-only and
                                  on-demand-only, and ArgoCD's own pods ask for
                                  capacity-type: spot. Skip this and ArgoCD
                                  never schedules, so there is nothing running
                                  to reconcile root.yaml. Replace ENV first, and
                                  verify the cluster security-group tag the
                                  NodeClass selects on — a NodeClass that matches
                                  nothing fails at runtime, silently.
         5  PUBLISH THE CHART     `chart-release.yaml` on a chart-v* tag. It has
                                  NEVER RUN (task 1.8) because there was no
                                  registry; step 0 of 3.4 creates it. Until
                                  0.1.0 exists in ECR, every Application fails
                                  at source resolution.
         6b argocd/ecr-credential.yaml  the CronJob that keeps the chart
                                  repository Secret current. An ECR token lasts
                                  12 HOURS, and when it lapses the Application
                                  keeps reporting Synced against the version it
                                  already has — a deploy that goes green and
                                  changes nothing.
         6c argocd/clusters.yaml  registers `dev` and `prod`. appsets/products.yaml
                                  addresses clusters by NAME; nothing resolved
                                  those names until this file existed. Fill
                                  DEV_CLUSTER_ENDPOINT and DEV_CLUSTER_CA_DATA
                                  from cluster-dev's outputs.
HAPPENS  namespaces, node pools, policy, ESO, KEDA, Gateway, cloudflared, Alloy,
         clamd, ArgoCD. The last manual command is `kubectl apply -f apps/root.yaml`.
KNOW IT  `kubectl get nodes` returns nodes on BOTH arm64 and spot — that is the
         proof step 0 worked, and it is the check that would have caught its
         absence. Then argocd app list shows root Synced and the ApplicationSets
         have generated Applications.
THEN     DELETE THE DEV CLUSTER AND REBUILD IT FROM THIS RUNBOOK. TIME IT.
         WRITE THE NUMBER INTO §13.
```

That last line is §13's demand, and until it happens the RTO figures there are
estimates. It is also the only way to find what is not in git — which is exactly
how the four items above were found, by tracing the path on paper instead.

---

# Part 4 — rova dev, the first workload

§17 was reordered on 2026-09-17. This part said qnsc-kb dev; **rova goes first**,
because it is the product that matters and proving a migration on a workload
nobody would notice proves the easy case. qnsc-kb dev is step 4 and gets its own
part when it arrives — its stack is already written at `infra/live/kb-dev`.

Two things that did NOT change with the order. Dev still precedes prod: rova prod
waits for this to soak, and it is a separate stack. And dev needs NO DATA
MIGRATION — the new platform has its own database, so the migrator Job creates the
schema in an empty one and developers reseed. §5d already says nothing in a
development environment justifies protecting its data.

**What DID change, on 2026-09-20: the cutover is no longer reversible by pointing
the hostname back.** §17b used to run new pods against the SAME database, which
made step 4 an undo button. The new estate is self-contained — its own VPC and its
own data tier, so that Phase 5 is a `tofu destroy` instead of surgery on a live
state — and the price is that in PRODUCTION the first write on the Kubernetes side
is the point of no return. Dev is unaffected, because dev has no data worth
rolling back to. Read §17b before scheduling any prod cutover; it carries both
migration options and what each costs in downtime.

## 4.1 Apply the product stack

```
DO       cd infra/live/rova-dev && tofu apply
         THEN: tofu output -raw role_settings_sql | psql "$ADMIN_URL"
HAPPENS  a database, two roles, eleven secret containers, three IRSA roles, the
         email-bounce SQS queue and its DLQ.
KNOW IT  ci/scripts/platform_conformance.py --root . passes with rova/dev PAIRED
DO NOT   skip the SQL. Until it runs, nothing bounds a noisy neighbour and the
         migrator carries the 30s application timeout rather than 600s.
WATCH    the cache index. rova's ECS develop stack uses db 0; §15b's consolidation
         gives rova db 2, because 0 is qnsc-kb's Celery broker. This stack sets 2.
         Everything else about the migration is like-for-like; this one value is
         deliberately different.
```

## 4.2 Write the secret values

```
DO       put a value in every container 4.1 created, under qnsc/dev/rova/app/
HAPPENS  nothing until ESO next syncs — the containers are created EMPTY (§8) and
         values never enter state or git.
KNOW IT  aws secretsmanager list-secrets shows eleven under the prefix, none empty
WHY      there is no DATABASE_PASSWORD among them, deliberately: §8 chose RDS IAM
         authentication, so no database password exists to store or rotate.
```

## 4.3 Build and deploy

```
DO       merge anything to rova's main
HAPPENS  rova/.github/workflows/k8s-deploy.yml calls ci's k8s-deploy reusable:
         images build as sha-<commit> for linux/arm64, CI edits
         gitops/values/rova/tags.dev.yaml, ArgoCD syncs, the migrator Job runs as
         a PreSync hook, pods start.
KNOW IT  rova's dev hostname answers, and the migrator Job shows Completed
WATCH    /v1/readyz — it reports postgres AND valkey, which is what tells you the
         cache index above is right. A green deploy with valkey down is the exact
         failure rova's own notes record from the 2026-08-17 cache migration.
FIRST    two repository secrets must exist, and neither is an agent's to create:
         GITOPS_DEV_TOKEN      write to the DEV path only. §10b — a token that can
                               write prod.yaml makes the promotion review
                               decorative.
         GITOPS_PROMOTE_TOKEN  opens the prod pull request, cannot merge it.
         And rova-github-ecr-push's OIDC trust must accept the two new workflow
         subjects. No new deploy role: the Kubernetes path touches no cluster, it
         edits one line in another repository.
```

**That workflow did not exist until 2026-09-19.** `ci`'s `k8s-deploy.yml` and
`k8s-promote.yml` were complete and nothing in the estate called either — rova
still called the ECS `backend-deploy.yml`, and this step used to read "with the
k8s-deploy workflow wired", which was a condition nobody had met. Both paths now
run side by side, which is what §17b requires: nothing leaves ECS until Phase 5,
and `ecs-run-task` keeps running every product's migrations until then.

## 4.4 Soak for one week

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
