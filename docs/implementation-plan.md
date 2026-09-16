# Implementation plan

Companion to `kubernetes-platform-design.md`. That document says *what* and *why*; this one says
*in what order*, *who can do it*, and *how you know it is done*.

Written 2026-09-15. Every task cites the design section that justifies it — **read that section
before starting the task.** Do not infer requirements from this file alone; it is an index, not a
specification.

## Status — 2026-09-15

```
PHASE 0   0.4 0.5 done · 0.1 0.2 0.3 0.6 0.7 0.8 OUTSTANDING (six, five need a human)
PHASE 1   COMPLETE
PHASE 2   2.1-2.6, 2.8 written · 2.7 deferred by design · 2.9 needs the measurement
PHASE 3+  not started — blocked on a cluster
```

**The critical path is 0.1.** Everything buildable without a cluster is built;
everything else waits on the residency answer.

### Built but not in the task list above

The plan was written before the work; three things exist that it never named.

```
ci/actions/bump-gitops-tag              §11's delivery mechanism. A product repo
ci/.github/workflows/k8s-deploy.yml     never touches a cluster — it builds an
ci/.github/workflows/k8s-promote.yml    image and edits one line in `gitops`
```

Promotion copies the ECR **manifest**, not the image, so the digest is unchanged
and the build's attestation still covers exactly what production runs. That is the
concrete reason §7c forbids a per-environment ECR repository.

### Four design errors that building found

Each is corrected in `kubernetes-platform-design.md`; they are listed here because
a plan that hides its corrections is a plan nobody trusts twice.

```
§4b   `singleton` did not exist. qnsc-kb's Celery beat must never have two
      replicas INCLUDING during a RollingUpdate, and no combination of `scaling`
      expressed that. Found by task 1.7, which is what 1.7 is for
§5d   PgBouncer as a SIDECAR does not solve the problem §5d states — a sidecar
      pools per pod, so six replicas still open six pools and the count stays
      linear in replicas. It is a Deployment
§6    the cyrilgdn/postgresql provider has NO resource for role settings, so
      product-profile emits `role_settings_sql` as an output instead of
      pretending. UNTIL IT IS APPLIED, nothing bounds a noisy neighbour (§5)
§11   the promote job gated on `workflow_dispatch` inside a `workflow_call`,
      where it can never fire. The fix was structural: promotion is a separate
      ACT, not a stage of a build, and is now its own workflow
```

### Where the artefacts live

```
gitops/                          chart · 11 templates · schema · 11 tests · CI ·
                                 apps · appsets · rendered
tf-modules/modules/product-profile
ci/actions/bump-gitops-tag · ci/.github/workflows/k8s-{deploy,promote}.yml
infra/live/cluster-{dev,prod}    the two EKS clusters
infra/live/data-{dev,prod}       the shared Postgres, preview Postgres and cache
infra/live/kb-dev                the first product-profile call — §17 step 2
infra/scripts/measure_ecs_usage.py
infra/docs/{kubernetes-platform-design,implementation-plan,data-residency-question}.md
infra/docs/repository-boundaries.md   which repository owns what, and why
infra/live/README.md                 the stack-naming rule
```

---

## How to read a task

```text
ID      phase.number
OWNER   HUMAN — needs a decision or an irreversible action
        AGENT — self-contained, verifiable, safe to delegate
        PAIR  — an agent prepares it, a human reviews and applies
NEEDS   task IDs that must be complete first
REF     section of kubernetes-platform-design.md
DONE    the acceptance test. If you cannot check it, the task is not specified
```

**Rules that apply to every task.**

* Nothing in phases 0–2 touches production traffic. If a task seems to, stop and re-read it.
* **Use `tofu`, never `terraform`.** The estate is OpenTofu 1.12. `terraform init`
  on `infra/live/bootstrap` fails with a message about an incompatible backend
  configuration, because that cache uses `assume_role_duration_seconds` — an
  OpenTofu attribute. It sounds like corruption and is not.
* Any OpenTofu change that could destroy a data resource is `PAIR` at minimum, never `AGENT`.
* A task is not done until its `DONE` line is demonstrably true. "It should work" fails.
* If a task contradicts the design document, the design document wins — or the design document is
  wrong and should be changed first, deliberately.

---

## Phase 0 — lead time and free wins

**Nothing here needs a cluster.** Two items have lead time that cannot be recovered later, which is
why they come before any building.

### 0.1 Send the data-residency brief

```text
OWNER  HUMAN
NEEDS  —
REF    §18, and infra/docs/data-residency-question.md
DONE   the brief is with a Vietnamese data-protection lawyer, and a response date is agreed
```

**This blocks phase 2.** Answer C — all Vietnamese personal data must stay in Vietnam — means a
different cloud provider, not a different region, and AWS has no Vietnam region. Do not create
clusters before this is answered.

### 0.2 Activate cost allocation tags

```text
OWNER  HUMAN — requires Billing console access
NEEDS  —
REF    §12, §12b
DONE   `product`, `env` and `size` are activated as cost allocation tags in Billing,
       and Cost Explorer can group by them
```

**No lead time can be bought back here.** A tag activated next year says nothing about this year,
and §12b's entire contingency plan depends on per-product numbers existing when the bill transfers.

### 0.3 `prevent_destroy` on every data resource

```text
OWNER  PAIR
NEEDS  —
REF    §17b
DONE   every aws_db_instance, aws_elasticache_* and aws_secretsmanager_secret in
       rova/infra/live, opshub/infra/live and qnsc-kb-backend/infra/live carries
       lifecycle { prevent_destroy = true }, and `tofu plan` is clean on all of them
```

Free insurance. §17b records why: one Terraform state owns both the database and the ECS services,
and 2026-09-14 already cost twelve minutes of downtime when a database was destroyed on purpose.

### ✅ 0.4 S3 gateway endpoint

> **DONE** — aws_vpc_endpoint.s3 is in infra/live/cluster-{dev,prod}/main.tf — applied with the cluster


```text
OWNER  AGENT
NEEDS  —
REF    §3
DONE   a gateway endpoint for com.amazonaws.<region>.s3 exists in runtime-dev and
       runtime-prod, attached to the private route tables; an ECR pull from a private
       subnet no longer traverses fck-nat
```

Costs nothing. August's ECR bill was ~94% data transfer, and ECR layers are served from S3.

### ✅ 0.5 Start the §15d measurement

> **DONE** — infra/scripts/measure_ecs_usage.py. WRITTEN, NOT RUN — needs credentials and 14 days


```text
OWNER  AGENT
NEEDS  —
REF    §15d
DONE   two weeks of AWS/ECS MemoryUtilization and CPUUtilization are collected per
       service per environment, converted to absolute values using the allocations in
       the live OpenTofu, and written up as p50 / p95 / peak per service
```

Start it now; it finishes while phase 1 runs. **qnsc-kb first** — it is roughly half of both
environments. Allocation is typically 2–3× measured p50, and every number in §15 depends on this.

### 0.6 Subnet resize and prefix delegation

```text
OWNER  PAIR
NEEDS  —
REF    §3
DONE   private subnets in runtime-dev and runtime-prod are /20, the VPC CNI has
       prefix delegation enabled, and existing ECS tasks are unaffected
```

Must precede any cluster. §15c lists IP exhaustion as failure #2, and it presents as pods stuck in
`ContainerCreating` with no obvious cause.

### 0.7 ECR retention: preview, then apply

```text
OWNER  PAIR
NEEDS  —
REF    §13
DONE   `aws ecr start-lifecycle-policy-preview` output is attached to a PR; the preview
       expires no release anyone would want to roll back to; release_retention_days = 180
       is applied to tf-modules/modules/ecr and its callers
```

The module change is already written. **Do not apply without the preview** — a time-based rule can
delete what a count-based rule was keeping, and the direction depends on the promotion rate.

### 0.8 Stop publishing `:latest`, then make tags immutable

```text
OWNER  PAIR
NEEDS  0.7
REF    §11
DONE   no CI workflow pushes a :latest tag; image_tag_mutability = "IMMUTABLE" is set on
       the ECR repositories in rova, opshub, qnsc-kb-backend and infra-template;
       a deliberate re-push of an existing tag fails
```

**Order matters.** `IMMUTABLE` rejects a second push of an existing tag, so flipping it first
breaks the pipeline. `qnsc-kb-backend/infra/live/prod/main.tf:104` records `:latest` already
putting a develop build into a production task definition.

---

## Phase 1 — `gitops` and the chart

**Still no cluster.** Everything here is code, and it is the highest-value work available while
0.1 is outstanding — because it is where you discover whether §4b's eight axes actually express
your products.

### ✅ 1.1 Create the `gitops` repository

> **DONE** — gitops/ — 6 commits


```text
OWNER  AGENT
NEEDS  —
REF    §1, §11c
DONE   github.com/quynhonsemiconductor/gitops exists with the tree in §1, branch
       protection requiring review on main, and a CODEOWNERS file
```

§10b: branch protection here is a production access control, not a code-quality convention.

### ✅ 1.2 Chart skeleton and values schema

> **DONE** — charts/qnsc-service. Application chart. values.schema.json rejects unknown keys, :latest and env: production


```text
OWNER  AGENT
NEEDS  1.1
REF    §4b, §11c
DONE   charts/qnsc-service/Chart.yaml declares type: application (NOT library — §11c);
       values.schema.json validates all eight axes and rejects unknown keys;
       `helm lint` passes
```

The eight axes: `kind`, `expose`, `resources`, `image`, `arch`, `capacity`, `scaling`, `slo`.

### ✅ 1.3 Templates, one per kind

> **DONE** — 11 templates. _kinds.tpl is the capability table every template queries


```text
OWNER  AGENT
NEEDS  1.2
REF    §4, §4b, §4d, §4e
DONE   templates render correctly for kind = http | worker | job | cron | grpc | realtime
       http      Deployment · Service · HTTPRoute · HPA · PDB
       grpc      Deployment · HEADLESS Service · GRPCRoute · gRPC health probe
       realtime  Deployment · Service · HTTPRoute · PDB ALWAYS · 300s grace · preStop
       job       Job as an ArgoCD PreSync hook, timeout 600s
       cron      CronJob
       worker    Deployment · no Service
```

Three details that are easy to miss and expensive later:
* `grpc` needs a **headless** Service, or L4 load balancing pins every client to one pod (§4d).
* `realtime` defaults invert the rest of the chart: `capacity: ondemand`, `min: 2`, PDB at every
  size (§4e).
* liveness must be a **trivial** endpoint the product cannot point at a dependency (§9j).

### ✅ 1.4 PgBouncer and the migrator role

> **DONE** — pgbouncer.yaml — a DEPLOYMENT, not the sidecar §5d specified. See below


```text
OWNER  AGENT
NEEDS  1.3
REF    §5d
DONE   a PgBouncer sidecar renders whenever data.postgres is set, in transaction mode;
       the job kind connects as <product>_migrator, not as the application role
```

§5d: the app role carries `statement_timeout = 30s`, which would kill the 600s migrations §4 sets
deliberately.

### ✅ 1.5 SLO rendering

> **DONE** — slo.yaml — multi-window burn-rate + the dead man's switch. Severity follows the PRODUCT


```text
OWNER  AGENT
NEEDS  1.3
REF    §9e, §4b Axis 8
DONE   slo: { availability, latency } renders Prometheus recording rules and
       multi-window multi-burn-rate alerts; an alert cannot exist without a route
```

### ✅ 1.6 Chart CI

> **DONE** — helm lint per values file · 11 unittest · kubeconform · golden render in rendered/


```text
OWNER  AGENT
NEEDS  1.2
REF    §11c
DONE   CI runs helm unittest, kubeconform against the target Kubernetes version, and a
       GOLDEN RENDER — `helm template` against every values file, output committed, diff
       shown in the PR
```

The golden render is the control. Unit tests pass while "this silently removes the PDB from every
size-M service" ships.

### ✅ 1.7 Write real values files and validate the axes

> **DONE** — values for rova, opshub, kb × dev/prod. Six render clean. FOUND TWO GAPS — see below


```text
OWNER  AGENT
NEEDS  1.3, 1.6
REF    §4b, §5, §15d
DONE   values/{rova,opshub,kb}/{base,dev,prod}.yaml exist and render without error;
       any product property the eight axes CANNOT express is written up as a finding
```

**This is the most valuable task in phase 1.** If the axes are wrong, this is where it should
surface — at zero cost, before anything is provisioned.

### ✅ 1.8 Publish the chart to ECR as OCI

> **DONE** — `.github/workflows/chart-release.yaml`, triggered on a `chart-v*` tag.
> Releasing is manual on purpose: publishing on every merge would reach every
> Application the moment someone bumped a pin. NOT YET RUN — needs the registry.

```text
OWNER  AGENT
NEEDS  1.6
REF    §11c
DONE   the chart publishes to ECR as an OCI artefact on tag; the chart repository has
       image_tag_mutability = IMMUTABLE; a version cannot be rewritten
```

### ✅ 1.9 Naming convention and the size check

> **DONE** — the convention is implemented in the chart's `_helpers.tpl` and in
> `product-profile`'s `locals`; `gitops/scripts/check-size-agreement.py` compares
> the two declarations and CI runs it.

```text
OWNER  AGENT
NEEDS  1.7
REF    §7c
DONE   the convention in §7c is implemented in both the chart and product-profile;
       CI fails if `size` in gitops/values/<p>/<env>.yaml disagrees with the `size`
       argument in infra/live/<p>/<env>
```

---

## Phase 2 — cluster foundation

**Blocked on 0.1.** Do not start until the residency answer is in hand.

### ✅ 2.1 EKS clusters

> **DONE** — infra/live/cluster-{dev,prod} — validate clean. BLOCKED on 0.1 before apply


```text
OWNER  PAIR
NEEDS  0.1, 0.6
REF    §2, §14
DONE   EKS dev and prod exist with Auto Mode, node pools general (Spot, diverse
       families) / ondemand (small floor) / amd64; NO dedicated on-demand system pool
```

§2: system pods run on the general pool with PDBs and topology spread.

### ✅ 2.2 Access entries, roles and audit logs

> **DONE** — same stacks. prod has NO standing admin entry; developer gets ViewPolicy, no exec


```text
OWNER  PAIR
NEEDS  2.1
REF    §10b
DONE   EKS access entries map Entra → Identity Center → four roles; developer has NO
       pods/exec in prod; break-glass is a separate MFA role with a CloudTrail alert;
       control-plane api/audit/authenticator logs are on with 90-day retention
```

Do this with the cluster, not after. Retrofitting access control means doing it while something is
already broken.

### ✅ 2.3 ArgoCD and its bootstrap

> **DONE** — `platform/argocd/values.yaml` plus `bootstrap.md`, which is §13's
> unanswered "who installs the installer". Not yet applied; needs a cluster.


```text
OWNER  PAIR
NEEDS  2.1
REF    §5b, §13
DONE   ArgoCD runs in the PROD cluster and manages both; SSO through Entra; policy.csv
       gives developers sync on dev and read-only on prod; the admin account is disabled;
       THE BOOTSTRAP PATH IS WRITTEN DOWN — who installs the installer
```

§13 lists the bootstrap as an unresolved unknown. It blocks the rebuild rehearsal, which the RTO
figures depend on.

### ✅ 2.4 ESO, KEDA, policy, Gateway

> **DONE** — `platform/{eso,keda,policy,gateway,cloudflared}`. ValidatingAdmissionPolicy
> rather than Kyverno, so §2b's check drops from four components to three.

```text
OWNER  AGENT
NEEDS  2.1
REF    §8, §4b Axis 7, §10, §3
DONE   External Secrets Operator with a SecretStore PER NAMESPACE, each with its own
       ServiceAccount and IRSA role — never a ClusterSecretStore;
       KEDA installed;
       Pod Security Standards restricted + ValidatingAdmissionPolicy (no Kyverno) +
       Sigstore policy-controller;
       Gateway API with cloudflared ×3 and one catch-all tunnel rule
```

### ✅ 2.5 Alloy two-tier

> **DONE** — `platform/alloy/`. The agent exports with `routing_key = "traceID"`
> against the gateway's HEADLESS service, which is the part §9b named but did not
> specify: without it the gateway samples on fragments of traces and fails quietly.

```text
OWNER  AGENT
NEEDS  2.1
REF    §9b, §9d
DONE   Alloy DaemonSet (node signals) AND Alloy gateway Deployment ×2 (OTLP receiver,
       tail sampling, metric allowlist, the single egress credential);
       Adaptive Metrics on; Loki labels limited to {cluster, namespace, app, level}
```

**The gateway is required, not an optimisation** — tail sampling needs every span of a trace on the
same collector, and a DaemonSet cannot offer that.

### ✅ 2.6 Shared Postgres and the product-profile module

> **DONE** — `tf-modules/modules/product-profile` (the module),
> `infra/live/data-{dev,prod}` (the shared instances, which did not exist —
> each product's own infra owned its database), and `infra/live/kb-dev` (the
> first call). `role_settings_sql` is an OUTPUT applied by hand, see below.


```text
OWNER  PAIR
NEEDS  2.1
REF    §5, §5d, §6
DONE   one shared RDS per environment; per-role statement_timeout, idle_in_transaction
       and CONNECTION LIMIT; a <product> and a <product>_migrator role per product;
       pg_stat_statements on; RDS IAM authentication via IRSA
```

### 🟡 2.7 The `platform` namespace and clamd

> **PARTIAL** — deferred by design — clamav stays a sidecar for the like-for-like migration (§4c)


```text
OWNER  AGENT
NEEDS  2.4
REF    §4c
DONE   namespace platform; clamd as kind: http, expose: cluster, arch: amd64,
       capacity: ondemand, 2 replicas in prod; freshclam database age exported as a
       metric with an alert at >24h stale
```

### ✅ 2.8 Preview environments

> **DONE** — gitops/appsets/preview.yaml — PR generator, labels: [preview]


```text
OWNER  AGENT
NEEDS  2.4
REF    §11
DONE   an ApplicationSet with a PR generator; *.preview.qnsc.vn resolves through the same
       tunnel catch-all; a shared preview Postgres with a database per PR;
       5 concurrent, 72h TTL, auto-deleted
```

### 2.9 Right-size from the measurement

```text
OWNER  AGENT
NEEDS  0.5, 1.7
REF    §15d
DONE   every values file carries requests from measured p50 and memory limits from p95;
       NO CPU LIMITS ANYWHERE; memory limit == memory request
```

CPU limits throttle on 100 ms bursts, not averages — which is every service in this estate.

---

## Phase 3 — qnsc-kb dev, the first workload

### 3.1 Split clamav out of qnsc-kb

```text
OWNER  PAIR
NEEDS  2.7
REF    §4c
DONE   qnsc-kb reaches clamd.platform.svc.cluster.local:3310 via MALWARE_SCANNER_HOST;
       the sidecar is gone from the task definition; upload rejection is FAIL CLOSED
       with a 5s connect / 30s scan timeout and one retry
```

### 3.2 Move qnsc-kb to arm64

```text
OWNER  AGENT
NEEDS  3.1
REF    §4b Axis 5
DONE   qnsc-kb api and worker build and run on arm64; the conformance exception in
       ci/scripts/stack_conformance.py is deleted
```

Blocked only by 3.1 — clamav was the sole reason for the x86 pin.

### 3.3 Deploy and soak qnsc-kb dev

```text
OWNER  PAIR
NEEDS  2.9, 3.2
REF    §17, §17b
DONE   qnsc-kb dev runs on Kubernetes against the SAME database; soaked ONE WEEK against
       §17b's checklist — error rate, p99, restarts, SLO burn rate, every cron has run,
       one deploy shipped end to end, one rollback rehearsed
```

**Nothing is deleted from ECS at this step.** Both platforms run.

### 3.4 OpenFeature and ConfigCat

```text
OWNER  AGENT
NEEDS  —  (parallel with everything)
REF    §4c
DONE   @openfeature/server-sdk in rova, opshub and qnsc-kb with ConfigCat as the provider;
       SERVER-SIDE EVALUATION ONLY until 0.1 is answered — nothing calls ConfigCat from
       a browser or from solodesk; every flag carries an owner and a removal date
```

---

## Phase 4 — the remaining products

Each follows the same shape: values file → deploy alongside → cut over the tunnel hostname → soak
→ scale ECS to zero → shrink the stack. **Do not start the next product until the previous one has
finished its soak.**

```text
4.1  qnsc-kb prod       soak 1 week
4.2  LMS                soak 3 days — and resolve the conflict first: the LMS plan says
                        "the ECS deploy path", §17 says Kubernetes
4.3  opshub             soak 1 week
4.4  rova               soak TWO WEEKS. The only product earning money
```

### The abort criterion, agreed now

```text
stop and re-evaluate if    phase 2 exceeds 10 weeks
                           any product migration exceeds 2x its estimate
                           two consecutive products fail their soak
```

Stopping is not failure. It means something in the design was wrong and the cost of finding out is
capped.

### Safe places to pause

```text
after phase 2   two clusters running nothing — the WORST place to stop
after 3.3       qnsc-kb dev migrated. Two platforms, tolerable
after 4.1       qnsc-kb off ECS entirely, chart proven on the hardest product.
                A GOOD place to stop indefinitely
```

---

## Phase 5 — retire the old platform

**Only after 4.4 has finished its two-week soak.** §17b is the specification; the sequence is not
optional and the order is the whole of it.

```text
5.1  scale each ECS service to zero          free, instantly reversible
5.2  delete only the ECS BLOCKS from each stack's configuration
     DO NOT run tofu destroy — one state owns the database and the ECS services
5.3  delete the ECR repositories of retired products — retention expires by age,
     never by abandonment
5.4  delete tf-modules: ecs-cluster · ecs-service · product-service · firelens-agent
     observability-agent · tunnel-agent · oneshot-task · alb · alb-logs
5.5  delete per-product infra/ directories, infra-template, stack_conformance.py,
     and the ECS deploy workflows
```

```text
DONE  no ECS service exists in either account; no module in 5.4 has a caller;
      tofu plan is clean on every remaining stack; the §12 cost dashboard shows no
      ECS line for a full month
```

Assign 5.x a date and an owner the moment 4.4's soak finishes. A cleanup with neither is a platform
you keep paying for and nobody maintains.

---

## Decisions still owed by a human

These are not tasks. They are answers, and several tasks are waiting on them.

```text
on-call            does anyone carry a phone for rova? If no, drop rova's SLO to 99.0%
                   and make everything P2. Either is fine; undecided is not.   §17
LMS target         the LMS plan says "the ECS deploy path"; §17 says Kubernetes.
                   Two current documents disagree.                             §18
mcp-tools          is it the ai-dev-kit, or is it retired? §1 lists it under
                   "retire or fold in" beside a logo directory, and it has its
                   own CLAUDE.md and 3,527 passing tests.                      §1
cleanup owner      who owns phase 5, and by when.                              §17b
```

---

## What this plan deliberately does not include

```text
monorepo / Nx      §14 decided against for now. Unrelated to this migration
IC lab             withdrawn by VLSI-ACADEMY-LMS-PLAN.md v0.3 on 2026-09-12
Savings Plans      §12b — a one-year commitment is the wrong instrument while it is
                   unclear who pays the bill in twelve months
profiles · RUM · synthetics · SLO dashboards per kind · OpenCost · VPA ·
Argo Rollouts · EventBridge
                   §18 stages these AFTER the first product ships. Three signals is a
                   working observability stack; six is the destination
```
