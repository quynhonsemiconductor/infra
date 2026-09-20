# Implementation plan

Companion to `kubernetes-platform-design.md`. That document says *what* and *why*; this one says
*in what order*, *who can do it*, and *how you know it is done*.

Written 2026-09-15. Every task cites the design section that justifies it — **read that section
before starting the task.** Do not infer requirements from this file alone; it is an index, not a
specification.

## Status — 2026-09-19

```
PHASE 0   0.2 0.3 0.4 0.5 0.6 0.7 0.8 done · 0.1 OUTSTANDING (human)
          0.3 shipped as a PLAN GATE, not prevent_destroy — see below
PHASE 1   COMPLETE
PHASE 2   2.1-2.8 written and MERGED · 2.7 COMPLETE (clamd now exists)
          2.9 needs the measurement
PHASE 3   rova dev — REORDERED from qnsc-kb, see §17. Stack written, not applied.
PHASE 4+  not started
```

**NOTHING HAS BEEN APPLIED.** Every stack in `live/` is written, validated and
merged; none has run `tofu apply`. The estate on AWS today is still the ECS one.

**The critical path is 0.1**, the data-residency determination. §17 calls region
"the single most expensive property to change", and step 1 creates the clusters.

### A blocker found before apply: nothing could have scheduled

Discovered 2026-09-19, while doing 0.6. **The clusters as merged could not run a
single pod in this estate, including ArgoCD.**

`cluster-{dev,prod}` enable Auto Mode with `node_pools = ["general-purpose"]`.
AWS documents that built-in pool as **amd64 only, on-demand only, and not
modifiable** — enable or disable, nothing else. `system` allows arm64 but carries
a `CriticalAddonsOnly` taint and §2 deliberately leaves it off.

Everything this estate renders asks for something that pool cannot give:

```
gitops/values/*/*.yaml         kubernetes.io/arch: arm64          every product
platform/argocd · eso · keda    karpenter.sh/capacity-type: spot
platform/alloy · gateway        karpenter.sh/capacity-type: spot
platform/cloudflared            arch: arm64 AND capacity-type: spot
```

ArgoCD is the one that makes this more than a workload problem: it never
schedules, so `gitops/apps/root.yaml` — the one thing installed by hand — has
nothing running to reconcile it. The bootstrap in §13 stops at step 5 and the
symptom is `Pending` with `0/N nodes are available: node(s) didn't match Pod's
node affinity/selector`, which reads like a broken manifest.

`cluster-prod/README.md` said system pods "run on the general SPOT pool". **That
pool was an intention, not a resource.** It is now
`gitops/platform/compute/{nodeclass,nodepools}.yaml`, and it is step 0 of
`platform/README.md`'s apply order, before ArgoCD.

**The guard is a sixth cross-repository contract.**
`ci/scripts/platform_conformance.py --only schedulable` walks every `nodeSelector`
under `gitops/rendered/` and `gitops/platform/`, reads the enabled built-in pools
out of the cluster stacks' HCL, and fails if any selector has no pool that can
satisfy it. Removing `platform/compute/` reproduces the original blocker as 29
findings, which is how it was verified.

It is the same shape as the other five: two repositories, each internally valid.
`tofu validate` passes because a node pool name is a string; `helm lint` and
`helm unittest` pass because a nodeSelector is a map.

### The platform has its own VPC — and Phase 5 is a destroy now

**Changed 2026-09-20, at the owner's direction: every resource the new estate needs
is NEW, so the old estate can be deleted wholesale rather than carved.**

```
live/platform-prod   10.93.0.0/16   NEW. public/private/data /24s + cluster /20s
live/platform-dev    10.92.0.0/16   NEW. same layout, fck-nat, SSM bastion
live/runtime-prod    10.91.0.0/16   the OLD VPC. UNTOUCHED — reverted to HEAD
live/runtime-dev     10.90.0.0/16   the OLD VPC. UNTOUCHED
```

`data-{dev,prod}`, `cluster-{dev,prod}`, `rova-dev` and `kb-dev` now read
`platform/platform-{dev,prod}` instead of `platform/runtime-{dev,prod}`. One line
each, because the new stacks export the same output NAMES deliberately.

**WHY, and it is not tidiness.** The new platform's data tier used to live inside
the old VPC — `data-prod` read `runtime-prod`'s `data_subnet_ids` and `sg_rds_id`.
You cannot destroy a VPC containing the database your new platform runs on, so
`runtime-prod` could only ever be carved, and Phase 5.2 was open-heart surgery on
a ~6,200-line state that owns both a live database and the ECS services beside it.
Now it is `tofu destroy` on stacks nobody uses — and that has an undo, because the
state is versioned in S3.

**WHAT IT COSTS.** ~$33/month for a second NAT in prod, ~$3 in dev, for the
overlap period. And the real one: §17b's step 3 was "run new pods against the SAME
database", which is what made the tunnel cutover an undo button. That is gone —
see the same-database correction below.

**Task 0.6 is therefore SUPERSEDED, not done differently.** The /20 subnets it
asked for exist, but in the new VPCs where they cost nothing and risk nothing —
not added to an applied production VPC. `runtime-{dev,prod}` are back at
`network-v1.3.1` and are not touched by this migration at all, which is the
strongest version of "existing ECS tasks are unaffected" the task could have had.

### The probe contract, which no application satisfied

**Found 2026-09-19 in the pre-apply audit; fixed 2026-09-20. Not one of the three
products served what the chart probed.** Their own Dockerfile HEALTHCHECKs are the
evidence:

```
             app actually served              chart probed
rova         /v1/healthz  /v1/readyz  :3000   /livez  /readyz
opshub       /v1/healthz  /v1/readyz  :3000   /livez  /readyz
qnsc-kb      /health/live             :8000   /livez  /readyz
```

Both NestJS apps call `setGlobalPrefix('v1')`, so every health route sits behind
`/v1`. Liveness would 404, the kubelet would restart the container, and the api
would sit in CrashLoopBackOff. Readiness would 404, so the pod never became Ready,
the Service never got endpoints, and the tunnel served nothing. ECS never surfaced
it: the ALB target group and the Dockerfile HEALTHCHECK already point at
`/v1/healthz`, so the chart was the only consumer guessing.

**A second, separate bug in the same place: `kind: worker` was given HTTP probes.**
The probe block was gated on `ne $caps.workload "Job"`, but worker's capability row
says `service: none` and rova's worker is explicit — "createApplicationContext: no
HTTP driver needed". With no `port` the probes fell back to `:8080` and asked an
unbound port for `/livez`. That was every worker in the estate, plus a
`startupProbe` on qnsc-kb's worker that was never reachable either.

Fixed in three places, because the contract has three ends:

```
chart      probes now gate on `$caps.service`, so non-HTTP kinds get none
values     rova and opshub set `readinessPath: /v1/readyz`
apps       rova and opshub serve a trivial `/livez` OUTSIDE the v1 prefix
           (setGlobalPrefix exclude + a @Public @Get('livez'))
```

Liveness could not be fixed from values and that is deliberate: the chart
hardcodes it (§9j) and `admission.yaml` DENIES any other path, so a prefixed
`/v1/livez` is a rejected manifest rather than a worse probe. The app change is
five lines and duplicates `healthz` rather than replacing it, because `/v1/healthz`
is load-bearing on the ECS path while both platforms run.

**All three products are fixed, and that consistency is the point.** qnsc-kb was
done last (2026-09-20) even though it is Phase 3b, because leaving one product on a
different probe contract is how this class of bug comes back — the next person reads
two products that agree and assumes the third does too.

```
                liveness        readiness              app change
rova            /livez :3000    /v1/readyz :3000       @Get('livez') + prefix exclude
opshub          /livez :3000    /v1/readyz :3000       @Get('livez') + prefix exclude
qnsc-kb         /livez :8000    /health/ready :8000    @app.get("/livez")
```

Every one serves `/livez` trivially and unprefixed, and every readiness probe points
at the path that application actually serves. kb needed no prefix exclusion — its
routes are mounted on the app directly, not behind a global prefix — and its
readiness went to `/health/ready` rather than a new route, because `readinessPath`
IS a chart value and adding a duplicate handler would have been the worse fix.

kb's worker also lost a `startupPath: /livez` that had been rendering an httpGet
probe against port 8080 on a Celery consumer with no HTTP server.

### The same-database contradiction, resolved

**The design document said one thing in five places and the code did the opposite.**
§17b: "Only compute moves… run the pods in the new cluster against the same
database… roll back by repointing it again." But `live/rova-dev` has always read
`postgres_host` from `platform/data-dev` — the NEW shared instance — not from
rova's existing develop RDS. Nobody reconciled them, and the contradiction decided
the cutover procedure and the rollback story.

Resolved in favour of the code, deliberately, because it is what makes deletion
cheap. The design document now says so, and says what it costs:

```
dev      NO MIGRATION. Start empty, the migrator Job creates the schema,
         developers reseed. §5d: nothing in a development environment justifies
         protecting its data. No network path needed between old and new.

prod     A REAL MIGRATION, and the only step in this plan that MUST be rehearsed
         before it is performed:
           write-freeze + dump/restore   downtime = dump + restore. Simple.
           logical replication           near-zero downtime, needs a temporary
                                         VPC peering connection, deleted after.
         THE ONE-WAY MOMENT is the first write on the Kubernetes side. Decide in
         advance how far back you are willing to go, because after it "roll back"
         means reverse-migrating the delta.
```

`prevent_destroy` (task 0.3) matters MORE under this shape: until the migration is
verified, the old database is the only copy of the truth.

### `observability` can plan now

Split, per the diagnosis below, which was correct and is no longer current:

```
live/observability            the Grafana Cloud ORG resources — stack, access
                              policy, service account and their tokens. Default
                              provider, configured from var.grafana_cloud_api_key.
                              PLANS CLEAN TODAY. Outputs the url and the token.
live/observability-alerting    folders, dashboards, contact point, notification
                              policy, rule groups. ONE non-aliased provider,
                              configured from the stack above via
                              terraform_remote_state. NOT_PLANNABLE until
                              observability is applied — the same shape as
                              cluster-dev needing cluster-prod, and for the same
                              reason, which is now what the exclusion says.
```

### Merge order, which is now load-bearing

`tf-modules` must merge and release-please must cut its tags **before** the
`infra` and product-repo changes can `tofu init`. Four modules changed and their
callers are pinned ahead of the tag, the same pattern as
`product-profile-v0.1.0` in #134:

```
network-v1.4.0  cluster_subnet_cidrs   CUT 2026-09-20 (tf-modules #147/#148)
ecr-v2.1.0      time-based retention   already existed; callers now take it
```

Every other forward pin was REVERTED on 2026-09-20 when task 0.3 was reverted.
`data-*`, `rova-dev`, `kb-dev` and the three product stacks are back on tags that
exist — `rds-v2.3.0`, `cache-v1.1.0`, `secrets-v2.1.1`, `product-profile-v0.1.0` —
and all six conformance contracts pass, including `module-refs`, for the first
time in this migration.

`platform_conformance.py --only module-refs` is what caught the forward pins while
they were invalid. It exists so a ref to a tag that does not exist cannot reach
main unseen (#135, #136), and it did its job.

Task 0.8 has its own order, inside that one: `ci`'s `:latest` removal must ship
**before** the four `IMMUTABLE` flips, or the pipeline fails on its next push.

### Blocked on a human, not on an agent

```
0.1  data-residency determination            blocks step 1, everything downstream
     SNS subscriptions — ALL SIX TOPICS      alerting_health has failed every
     have zero subscribers                   scheduled run since 2026-09-14
     the apply sequence itself               needs AWS credentials
     writing the secret VALUES               containers are created empty (§8)
     0.7's lifecycle-policy PREVIEW          infra/scripts/ecr_lifecycle_preview.py
                                             is written and fails loudly with no
                                             credentials; a human runs it and
                                             attaches the artefact to the PR
     verify the cluster SG tag               gitops/platform/compute/nodeclass.yaml
                                             matches kubernetes.io/cluster/qnsc-ENV
                                             = owned. A NodeClass that matches
                                             nothing fails at RUNTIME, silently
```

The SNS one matters more than it looks: `qnsc-security-alerts` is where
`cluster-prod`'s break-glass rule publishes, so applying the cluster arms a rule
that reaches nobody. AWS deletes an unconfirmed email subscription after ~3 days
and Terraform reports success either way, so a clean plan proves nothing here.

### One stack still cannot plan

```
organization    AccessDenied on sso:DescribePermissionSet and organizations:*.
                CAUSE NOT ESTABLISHED, deliberately: the plan role carries
                ReadOnlyAccess, which already allows those. The SSO error says
                "the resource does not exist in this Region", and both services are
                scoped in ways a region-pinned provider can miss. Needs credentials
                to settle. Do not guess — a wrong cause was written here once and
                cost an afternoon.
```

The `observability` diagnosis that used to sit beside it is resolved above. It is
kept here because the shape of it generalises: **the fix was structural, and the
obvious answer — pass a credential — was already true.** `grafana_folder` and
`data.grafana_data_source` used the `grafana.stack` provider ALIAS, whose `url`
and `auth` were attributes of `grafana_cloud_stack` resources in the same stack.
Unknown until those exist, so the provider could not configure.

### Apply order, which is also the dependency chain

```
bootstrap           RE-APPLY — it now creates the chart's OCI repository (1.8)
security-baseline   CONFIRM only — three role ARNs + the alert topic exist
platform-prod       NEW VPC, 10.93.0.0/16. Nothing touches runtime-prod.
data-prod           shared Postgres, preview Postgres, the one cache — in the NEW VPC
cluster-prod        FIRST cluster — it outputs argocd_role_arn
platform-dev        NEW VPC, 10.92.0.0/16
data-dev
cluster-dev         consumes argocd_role_arn (ArgoCD is hub-and-spoke, §2)
gitops/platform/    compute/ FIRST, then the chart publish, ESO/KEDA/Alloy, ArgoCD
rova-dev            the first workload

runtime-prod and runtime-dev are NOT in this list. They are the OLD VPCs and this
migration does not touch them — that is what makes Phase 5 a destroy.
```

Each stack below `platform-*` is unplannable until the stack above it is applied —
they read remote state that does not exist yet — which is why they sit in
`NOT_PLANNABLE` in `.github/workflows/infra-plan.yml` rather than failing CI.

**`platform-prod` and `platform-dev` are the only two of the new stacks that plan
clean today, and that is the point:** a VPC reads no remote state, so it depends on
nothing and goes first. `data-*` and `cluster-*` LEFT the plannable set on
2026-09-20 when they were repointed off the applied old VPCs onto these.

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

*(Five, as of 2026-09-19 — see §2 at the end.)*

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

§2    "node pools general (Spot, diverse families) / ondemand / amd64" was
      written as a property of the CLUSTER and implemented as
      `node_pools = ["general-purpose"]`, which is AWS's built-in pool:
      amd64 only, on-demand only, NOT MODIFIABLE. Auto Mode manages nodes, so
      §2 read like a cluster setting; it is a Kubernetes object. Nothing in the
      estate could have scheduled — including ArgoCD, which makes it a bootstrap
      failure rather than a workload one. Found 2026-09-19 by reading the
      rendered manifests against the AWS documentation for that pool, not by
      any test: every test passes, because a node pool name is a string and a
      nodeSelector is a map. Now `gitops/platform/compute/`, guarded by
      `platform_conformance.py --only schedulable`
```

### Where the artefacts live

```
gitops/                          chart · 11 templates · schema · 11 tests · CI ·
                                 apps · appsets · rendered
gitops/platform/compute          NodeClass + NodePools — §2's pools, step 0 of the
                                 platform apply order, before ArgoCD
gitops/platform/clamd            §4c's clamd, idle until 3.1 by design
tf-modules/modules/product-profile
ci/actions/bump-gitops-tag · ci/.github/workflows/k8s-{deploy,promote}.yml
ci/scripts/platform_conformance.py    SIX cross-repository contracts
infra/live/platform-{dev,prod}   the NEW VPCs — the estate's own network
infra/live/cluster-{dev,prod}    the two EKS clusters
infra/live/data-{dev,prod}       the shared Postgres, preview Postgres and cache
infra/live/kb-dev                the first product-profile call — §17 step 2
infra/live/observability         the Grafana Cloud org resources — plans clean
infra/live/observability-alerting  folders, dashboards, alerts — needs the above
infra/scripts/measure_ecs_usage.py
infra/scripts/ecr_lifecycle_preview.py   0.7's preview, fail-loud without creds
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
* **Use `tofu`, never `terraform`.** `terraform init` on `infra/live/bootstrap`
  fails with a message about an incompatible backend configuration, because that
  cache uses `assume_role_duration_seconds` — an OpenTofu attribute. It sounds
  like corruption and is not.
* **The estate pins OpenTofu 1.9.1, not 1.12.** This line said 1.12 until
  2026-09-20 and it was wrong, which cost a reverted change — see task 0.3. The
  real pin is `1.9.1` in every `TOFU_VERSION` in `infra`, `rova`, `opshub` and
  `qnsc-kb-backend`, in `ci/.github/workflows/infra-plan.yml`'s default, in
  `tf-modules/.github/workflows/ci.yml`'s `iac-lint` call, and in
  `infra-template/.opentofu-version`. There is no single source of truth for it,
  which is why it was easy to believe otherwise.
  **A local `tofu` newer than 1.9.1 will accept configuration CI rejects.** Check
  your version before concluding that a language feature is available.
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

### ✅ 0.3 Stop a plan that would lose data

> **DONE 2026-09-20, AND NOT WITH `prevent_destroy`.** The task named a mechanism;
> what it actually asks for is that nobody can approve a green plan that deletes a
> database. `prevent_destroy` is one way to get there and, on this estate, the
> wrong one.
>
> **Attempt one, reverted.** A `protect_from_destroy` module variable driving
> `lifecycle { prevent_destroy }`. CI rejected it: every workflow pins **OpenTofu
> 1.9.1**, and variables in a `lifecycle` block are a later feature — 1.12 accepts
> and enforces them, 1.9.1 fails validate with "Variables not allowed". The
> verification was done on a local 1.12.3 and generalised from this document's own
> false claim that the estate was 1.12.
>
> **Attempt two, rejected before writing it.** Hardcoding `true` in the modules
> would work on 1.9.1 and block two operations this estate documents as necessary,
> because `prevent_destroy` refuses REPLACEMENT as well as deletion:
>
> ```
> docs/rova-subnet-group-rebuild.md   an RDS instance replaced to correct a subnet
>                                     group name. Already performed once
> the secrets module's comments       develop deletes secrets immediately on
>                                     teardown so a destroy+redeploy does not hit
>                                     "secret scheduled for deletion"
> ```
>
> It also lives in the wrong repository: data resources are declared in
> `tf-modules`, so protecting a type is a module release plus a caller bump in four
> repositories — and it protects by TYPE, forever, rather than by what a specific
> change is about to do.
>
> **What shipped: a plan-time gate.** `ci/actions/plan-guard`, wired into
> `infra-plan.yml`, reads `tofu show -json tfplan` and fails the job if any data
> resource is being deleted or replaced. Properties that fall out of reading the
> proposed change rather than annotating the declaration:
>
> ```
> version-independent   parses plan JSON, which 1.9.1 emits happily. No upgrade,
>                       and no change to the binary that will apply production
> blocks nothing        the subnet-group rebuild still works. The plan just has to
>                       declare that it is doing it
> covers what is not    any aws_db_instance, aws_rds_cluster, postgresql_database,
> written yet           aws_elasticache_*, aws_secretsmanager_secret, aws_s3_bucket,
>                       aws_dynamodb_table or snapshot — including ones added later,
>                       with no per-module plumbing
> fails in REVIEW       which is the gap deletion_protection leaves. §17b's
>                       2026-09-14 incident happened WITH deletion_protection on:
>                       the destroy was authorised, protection was turned off first,
>                       in the same change, by someone who had read the plan
> ```
>
> **The override is a file, deliberately.** To destroy a data resource you add its
> address to `.allow-data-destroy` in the stack directory, with a reason after `--`.
> Not a workflow input and not a PR label, because both vanish from the record. A
> file is a diff someone reviews, it has to be removed afterwards, and the guard
> reports a stale entry so that it is — the same shape as the lesson in
> `modules/.checkov.baseline`, where suppressions keyed to something specific
> stopped matching when the situation changed.
>
> An allowance with no reason is refused rather than accepted. "Someone added a line
> once" is not a decision anybody can review later.
>
> **What is NOT protected, and why.** `aws_db_subnet_group` and
> `aws_db_parameter_group` are absent from the list: they hold no data, they point
> at it, and one of them is the subject of the documented rebuild. The test is
> reproducible-from-git, not importance — which is why an ECS service, a security
> group and a route table are absent too. **Protect what holds data, not what points
> at it.**
>
> 19 tests in `ci/tests/test_plan_guard.py`, including the three ways a guard like
> this passes when it should not: a replace disguised as a create, an unreadable
> plan document, and an allowance with no reason.
>
> `deletion_protection = true` stays on production RDS as the AWS-side backstop.
> The two are complementary: one makes the API refuse, the other makes the review
> refuse.

```text
OWNER  PAIR
NEEDS  —
REF    §17b
DONE   every aws_db_instance, aws_elasticache_* and aws_secretsmanager_secret in
       rova/infra/live, opshub/infra/live and qnsc-kb-backend/infra/live carries
       lifecycle { prevent_destroy = true }, and `tofu plan` is clean on all of them
```

The second half of that `DONE` line still needs credentials. What is verified
offline: the modules validate, a harness instantiating them with the real callers'
arguments validates at `true` and at `false`, and enforcement was demonstrated on
a throwaway resource.

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

### ✅ 0.6 Subnet resize and prefix delegation

> **SUPERSEDED 2026-09-20 — the /20s exist, in NEW VPCs.** The additive subnets
> described below were reverted: `runtime-{dev,prod}` are back at HEAD and this
> migration does not touch them at all. `live/platform-{dev,prod}` carry the /20
> cluster tier instead, where it costs nothing and risks nothing. That is a
> stronger form of this task's own acceptance test — "existing ECS tasks are
> unaffected" — than editing an applied production VPC could ever be.
>
> The analysis below still stands and is why the task could not be done as
> written. Kept because both halves were wrong and a plan that hides its
> corrections is a plan nobody trusts twice.
>
> * **The resize does not exist.** AWS has no operation that resizes a subnet, and
>   `cidr_block` on `aws_subnet` forces replacement. `runtime-prod` is applied with
>   production ECS ENIs in `10.91.10-12.0/24`, so editing those lines plans a
>   destroy the EC2 API refuses part-way. The acceptance test below — "existing
>   ECS tasks are unaffected" — is what makes the stated method impossible, not
>   merely risky. `cluster-prod/README.md` called it "not reversible under load";
>   it is not available.
>   **Done instead:** `cluster_subnet_cidrs`, a fourth tier at
>   `10.9x.{32,48,64}.0/20`, routed through the existing private route tables so it
>   inherits NAT egress and §3's S3 gateway endpoint for free. The ECS /24s do not
>   move, so the step is reversible by emptying one list — which the resize never
>   was. Both cluster stacks now read `cluster_subnet_ids`.
> * **Prefix delegation is already on and cannot be configured.** Auto Mode
>   defaults to /28 prefixes, and AWS states that VPC CNI configuration options do
>   not apply to Auto Mode. No work, and nothing to add — a `vpc-cni` addon here
>   would be inert.
>
> The module validates the size and the count and rejects a /24 with §15c's reason
> in the error. It cannot catch an overlap with a sibling tier, which is why
> `10.9x.16.0/20` — the tempting answer — is called out in the comment: it swallows
> the data subnets.

```text
OWNER  PAIR
NEEDS  —
REF    §3
DONE   private subnets in runtime-dev and runtime-prod are /20, the VPC CNI has
       prefix delegation enabled, and existing ECS tasks are unaffected
```

Must precede any cluster. §15c lists IP exhaustion as failure #2, and it presents as pods stuck in
`ContainerCreating` with no obvious cause. Auto Mode makes it arrive sooner than §3 implies: it
reserves a **/28 per node up front**, so a /24 is roughly fifteen nodes per AZ.

### 🟡 0.7 ECR retention: preview, then apply

> **CODE DONE 2026-09-19; THE PREVIEW IS A HUMAN STEP.** The module change was
> already written AND already tagged — `ecr-v2.1.0`, carrying
> `release_retention_days = 180` — and no caller had taken it; all four sat on
> `ecr-v2.0.0`. They are now on `ecr-v2.1.0`, which is the one bump in this batch
> with **no ordering dependency**, because the tag exists.
>
> One latent break found on the way: `qnsc-kb-backend`'s caller was already passing
> `release_retention_days` to a `v2.0.0` pin that has no such variable.
>
> `infra/scripts/ecr_lifecycle_preview.py` is the remaining step, made runnable:
> it builds the exact `ecr-v2.1.0` policy per repository, covers all nine, runs
> start-then-get, and emits an attachable artefact whose acceptance test is **"0
> release-tagged (`v*`) images expire"**. It is fail-loud per #129 and #132 — with
> no credentials it exits non-zero, names every repository it could not read, and
> writes an artefact marked INCOMPLETE. It never prints a clean verdict on data it
> did not read.

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

### ✅ 0.8 Stop publishing `:latest`, then make tags immutable

> **DONE 2026-09-19, in that order.** There was exactly one `:latest` push in CI —
> `extra-tags: latest` in `ci/.github/workflows/backend-deploy.yml`'s build job,
> the reusable workflow every product calls. Removed; `main` builds still push the
> immutable `sha-<commit>`. Then `image_tag_mutability = "IMMUTABLE"` on all four
> callers.
>
> **The shipping order is a constraint, not a preference:** `ci` must land and
> deploy before the four flips, or the pipeline fails on its next `:latest` push.
>
> **Three consumers still reference `:latest`, and they are reported rather than
> silently broken:**
>
> ```
> rova · opshub · qnsc-kb develop stacks   image_tag = "latest" in the ECS task
>                                          definitions. Retired at Phase 5; until
>                                          then develop must move to sha-<commit>
>                                          on the gitops path
> infra-template                           hardcoded in live/{develop,prod}/main.tf
>                                          and TF_VAR_image_tag defaults to
>                                          "latest" in both its workflows
> ```
>
> Also found, reported not fixed: **the chart's OCI repository does not exist as
> OpenTofu.** Task 1.8 requires it be `IMMUTABLE`, and `chart-release.yaml`'s
> comments say so, but there is no `aws_ecr_repository` for it anywhere — only an
> IAM pattern referencing it at `cluster-prod/iam.tf:239`. It is not `IMMUTABLE`
> because nothing manages it.

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
> `product-profile`'s `locals`; `ci/scripts/platform_conformance.py`'s `size`
> contract compares the two declarations and CI runs it. (It replaced
> `gitops/scripts/check-size-agreement.py`, which this line used to name.)

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

### ✅ 2.7 The `platform` namespace and clamd

> **DONE 2026-09-19.** The namespace half was already done — `namespaces/platform.yaml`
> exists with PSS restricted and `qnsc.vn/tenant: platform`, which is what keeps it
> exempt from policies written for products.
>
> **The handoff's claim that "the manifests exist in gitops/platform/" was false
> for clamd.** There was no clamd manifest anywhere; only `images.clamav: "1.5"` in
> `versions.yaml` and a chart-side NetworkPolicy naming a Service that did not
> exist. Now `gitops/platform/clamd/`: Deployment + ClusterIP on 3310 +
> NetworkPolicy, `arch: amd64` and `capacity: ondemand` as nodeSelectors the new
> `ondemand` NodePool can satisfy, 2 replicas in prod and 1 in dev, restricted PSS
> with `readOnlyRootFilesystem` and emptyDirs for the signature database, no CPU
> limit, and a freshclam-age exporter sidecar.
>
> **The §4c tension is real and is written into the manifest header.** clamav stays
> a SIDECAR inside qnsc-kb for the like-for-like migration; task 3.1 is what
> repoints the client at this Service and removes it. So between now and 3.1 this
> Deployment runs with **zero clients**, and that idleness is the designed state,
> not dead code. The header says "DEPLOYED BUT NOT YET USED. DO NOT DELETE."
>
> The alert severity follows from something worth stating plainly: **a stale clamd
> is worse than a down one** — it accepts scans and passes infected files, so the
> failure is silent. `ClamdSignaturesStale` (>24h) and `ClamdNoSignatureDatabase`
> are P1, plus a dead-man's switch on the metric being absent at all.
>
> One follow-up belonging to 3.1: Alloy's metric allowlist (§9d) must gain
> `clamav_signature_age_seconds`, or the alert evaluates against a series that
> never arrives — the same quiet-failure shape as §9b's sampling bug.

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

## Phase 3 — rova dev, the first workload

**Reordered 2026-09-17.** This phase was qnsc-kb dev. §17's table had rova last
("the only product earning money"); the product owner reversed it, because proving a
migration on a workload nobody would notice proves the easy case. qnsc-kb moves to
Phase 3b — its stack is written at `live/kb-dev` and is unchanged.

The trade, so it is not rediscovered: qnsc-kb prod has NO state file, so kb dev had
nothing at stake. rova dev is a real environment developers use. Still dev, not
revenue, and §17b's cutover is reversible at every step. The other cost is schedule:
kb exercises PgBouncer, the `worker` kind, KEDA, a 1.5 GB ONNX startupProbe and
clamav; rova exercises none of the last three, so whatever they break is found in 3b.

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
DONE   qnsc-kb dev runs on Kubernetes against ITS OWN database — dev starts empty and
       the migrator Job creates the schema (§17b, revised 2026-09-20); soaked ONE WEEK against
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
5.2  DESTROY the old stack outright — `tofu destroy` on the product's
     infra/live/<env> and, once every product has left it, on runtime-{dev,prod}
     THIS CHANGED ON 2026-09-20. It used to read "delete only the ECS BLOCKS from
     each stack's configuration. DO NOT run tofu destroy — one state owns the
     database and the ECS services", which was correct while the new platform
     depended on the old estate's data tier and network. It no longer does: the
     Kubernetes estate has its own VPC (live/platform-{dev,prod}) and its own
     databases (live/data-{dev,prod}), so nothing load-bearing remains inside the
     old stacks once traffic has moved and the data migration is verified.
     A destroy is also an action with an undo — state is versioned in S3 — which
     the surgery never was, on a 6,200-line state holding a live database.
     ⚠ VERIFY THE MIGRATION FIRST. The old database is the only copy of the truth
     until then; §17b's step 3 is what makes this safe, not this step.
5.3  delete the ECR repositories of retired products — retention expires by age,
     never by abandonment
5.4  delete tf-modules: ecs-cluster · ecs-service · firelens-agent
     observability-agent · tunnel-agent · oneshot-task · alb · alb-logs
     (product-service is ALREADY GONE — it was dead independently of ECS, since
     no ECS stack referenced it either)
5.5  delete per-product infra/ directories, infra-template, stack_conformance.py
     + stack-conformance.yml, and the ECS delivery path in `ci`:
       backend-deploy.yml · run-db-migration · ecs-run-task
     (verify-ecs-deploy is ALREADY GONE — superseded by an inline step)
     ecs-run-task is LOAD-BEARING until then: run-db-migration uses it and
     backend-deploy uses run-db-migration, so it runs every product's database
     migrations. It goes with them, not before.
```

**Expect checkov to get louder at 5.4, and do not read that as a regression.**
Deleting `product-service` did exactly this: six suppressions in
`modules/.checkov.baseline` were keyed on addresses that existed only because that
module wrapped them (`module.service.aws_lb_target_group.this`,
`module.firelens_agent.module.config_bucket.…`). Remove a wrapper and the
suppressions stop matching, so findings that were always there surface at the real
address. They were re-recorded at the resources themselves, where no future
wrapper can move them — do the same for whatever 5.4 unmasks, rather than
regenerating the baseline, which drops entries as well as adding them.

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
