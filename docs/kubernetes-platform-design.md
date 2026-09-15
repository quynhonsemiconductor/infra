# Platform design for seven products: EKS, ArgoCD, and one chart

Status: **proposed, nothing provisioned.** Written 2026-09-14, revised 2026-09-14. Supersedes the
compute half of `product-service-extraction.md`; the reasoning in that document about *why*
duplication is the core problem still holds and is the reason this one exists.

### What the revision changed

Recorded here rather than silently folded in, for the same reason §"An honest record of the
argument" exists — a reader should be able to see which conclusions moved and why.

```
§4b   four axes → eight. arch, capacity, scaling and slo were platform decisions
      being made per product; now they are values
§4c   NEW. Platform services as a category — clamav one service instead of a
      sidecar per task, acting on a decision qnsc-kb's own code already recorded
§5    shared Postgres is now the DEFAULT, not the XS fallback. Largest single
      number in the document, and the hardest item here to retrofit
§5d   NEW. The shared data tier defined: pooling, per-role limits, Aurora
      Serverless v2 for dev, ElastiCache removed rather than shrunk
§7b   NEW. The five paths, stated once
§9    three signals → six. Two-tier Alloy, because tail sampling needs a gateway
      the first draft did not have
§9j   NEW. Performance — probe discipline, cross-AZ traffic, edge caching
§10   Kyverno → ValidatingAdmissionPolicy. Lab cluster deferred to a namespace
§15b  NEW. What the rest of the document takes off the cost model: ~$756 → ~$400-450
§15c  NEW. What breaks first, in the order it arrives
§17   qnsc-kb dev first — the first milestone no longer waits on an undecided
      language choice

second pass
§4d   NEW. Polyglot — the seven things the platform asks of a service, and what
      Go and gRPC need. `kind: grpc`, client-side load balancing, buf contracts
§4e   NEW. Realtime — SSE first; `kind: realtime` because this document's Spot
      and consolidation defaults are hostile to long-lived connections
§5d   CORRECTED. Redis is not removable: it is qnsc-kb's Celery broker, the
      shared cache, rate limiting and now the realtime backplane. The saving is
      ~$8 from consolidation, not ~$25 from removal
§6b   NEW. Messaging — SQS and EventBridge, no new broker, with one control per
      failure recorded in rova's audit relay
§11   Preview environments gain a second justification: they remove the
      localstack-versus-Terraform drift that hid three messaging bugs

third pass
§10b  NEW. Human access — Entra through Identity Center, four roles, no standing
      production admin, no `kubectl exec` in prod, control-plane audit logs.
      Previously the largest undefined control in the design
§11c  NEW. Chart versioning — the single chart is a dependency shared by every
      service, and a bad version reached all of them at once. Pinned per
      Application, promoted like an image tag, gated by a golden render diff.
      Also changes §4's "library chart" to an application chart

fourth pass — mostly deletions
§decision  The IC lab driver is WITHDRAWN. VLSI-ACADEMY-LMS-PLAN.md v0.3
      (2026-09-12) removed the laboratory plane two days before this document
      was written. Three drivers become four, one of which is gone; cost is now
      the primary quantitative justification
§10   The whole lab isolation design deleted — gVisor, session pods, tainted
      pool, dedicated cluster. No hostile-code tenant exists in this estate
§2 · §4 · §4b · §17   `session` and `stateful` kinds, the `lab` node pool and
      migration step 7 removed. The amd64 pool for clamd takes the pool slot
§13   NEW. Rollback has an expiry date — ECR expires by COUNT while the promise
      is in TIME. Plus: secrets are regenerated, not restored
§15b  the lab line was never a saving; removing it moves the total UP to ~$505-555
§15d  NEW. Measure before sizing, and the requests/limits rule:
      no CPU limit, memory limit == request
§17   NEW. Three non-platform dependencies with owners outside this document:
      the data-residency determination before step 1, and an incident-response
      policy that matches the SLO numbers

fifteenth pass
§1 · §7c · §11c · §17b and implementation-plan.md
      The `delivery` repository is renamed **`gitops`**. It reads as a business
      noun in a semiconductor company and needed explaining; `gitops` is
      self-documenting to anyone who has used ArgoCD, and names the pattern
      rather than the tool. §7c gains a repository-naming rule: products are
      named for the product, platform repos for their function

fourteenth pass
§4c   Feature flags leave the cluster. Self-hosted Flagsmith is replaced by
      OpenFeature in the applications with ConfigCat as the provider — nothing
      to run, nothing in §2b's upgrade list, no database on the shared instance.
      LaunchDarkly excluded on pricing shape (per-seat AND per-context is wrong
      for B2B). `flagd` recorded as the exit, with two triggers. One rule while
      §18's residency question is open: SERVER-SIDE EVALUATION ONLY, so user
      context never leaves Vietnam
§5c   The cross-environment dependency analysis no longer has a subject, but is
      kept as the rule for whatever prod-only shared service arrives next
§17   Step 2 was Flagsmith. It is now qnsc-kb DEV — prod has no state file, so
      the risk is genuinely low, and it proves PgBouncer, the migrator role, the
      worker kind, KEDA, the startupProbe and the clamav split at once

thirteenth pass
§7c   NEW. Naming, so nothing has to be passed between repositories. A name
      encodes exactly the dimensions the thing varies on — which is why ECR
      repositories must NOT carry an environment, or promotion would mean
      copying bytes and the attestation would stop covering production. Full
      table, plus four decisions the existing estate forces: `dev`/`prod` with
      RDS identifiers grandfathered, underscores inside Postgres, the qnsc-kb
      slug shortened to `kb` (nearly free, since §4c rebuilds those images
      anyway), and a shape for preview namespaces. `size` is the only fact
      declared twice, and it gets a ten-line CI check rather than a generator

twelfth pass
§14   MONOREPO DECIDED AGAINST for now. Every repository stays where it is. The
      reasoning is kept in full — including the clarification that a monorepo
      would never have merged the products: images, databases, namespaces,
      Applications, deploys and releases would all have stayed separate, and
      only the location of source files in git would have changed. Deferred
      because it is unrelated to this platform, costs 1-2 weeks, and was only
      ever a 60/40 call
§1 · §4d · §17 · §18   Nx and the monorepo removed from the active plan. The
      migration no longer has a repository-layout dependency

eleventh pass
§17b  NEW. Running parallel, and retiring the old platform. The strategy is to
      build alongside and clean up afterwards, and the trap is that one
      Terraform state owns both the database and the ECS services — so
      `tofu destroy` on the old stack destroys production data. prevent_destroy
      first, then SHRINK the old stack rather than destroying it. Plus: what
      "all good" means as a checkable list, soak durations, an abort criterion,
      where it is safe to pause, and a cleanup inventory with a definition of
      done
§17   "The data does not move" now says why that is misleading about state

tenth pass — closing the known gaps
§11   Two tags, two lifecycles: `sha-` is identity and what DEV deploys, `v` is
      the promotion record and PROD only. That is why §13's retention rules are
      keep-20 and 180-days rather than two arbitrary numbers. And `:latest` is
      forbidden by this design while all four repositories enable it — the fix
      is ordered: stop publishing it, THEN flip IMMUTABLE
§5d   A second database role per product. The 30s statement_timeout would have
      killed the 600s migrations §4 sets deliberately; DDL rights move off the
      runtime role at the same time
§12c  NEW. Stopping a product — the checklist §12b's tier 4 made load-bearing.
      ECR is the one that bites, because retention expires by age, never by
      abandonment
§13   ArgoCD's own bootstrap marked Open with a proposed answer
§15e  The frontends are already split (Vite on Pages, never pods), LMS re-sized
      to its own plan, and the principle: do not split across platforms, because
      that recreates the seven copies in different clothes
§17   The stack_conformance.py question marked Open — replaced, not ported
§18   NEW. Readiness — blockers, decisions, unapplied work, untrue claims, and
      the timeline corrected from 6-10 weeks to 12-16, or 6-8 staged

ninth pass
§12b  NEW. The day the bill transfers. TrueIDC funds AWS today, so cost
      reduction is a CONTINGENCY, not a task. Tags and measurement have lead
      time and happen now; the levers are values changes and wait. Tier table
      with the floor: ~$340 at seven products, ~$220 at three. Savings Plans
      and reserved instances WITHDRAWN as recommendations — a one-year
      commitment under someone else's funding becomes ours when it ends
§15e  the reserved-capacity lines struck through and pointed at §12b

eighth pass
§2    The dedicated on-demand `system` pool is REMOVED — §2 specified one and §15
      never priced one. System pods run on the general Spot pool with PDBs and
      topology spread; instance-family diversity beats two on-demand nodes.
      Avoids introducing ~$100-140/month. vCluster named as the priced
      alternative to the dev control plane (~$100/month, not taken)
§15e  NEW. Components worth deleting rather than tuning: verify the Grafana free
      tier before paying $75 for it, question self-hosted feature flags, drop
      OpenCost. Control planes are now 28% of the bill, so the levers moved from
      compute to the fixed floor

seventh pass
§5    The presets are criticality TIERS, not resource sizes — every row in the
      table is an availability property. rova is the proof: size L and the
      smallest workload in the estate, because it is the one earning money
§4c   The e5-large-instruct ONNX session (~1.5 GB resident, loaded by both api
      and worker) is the second clamav. Extracting it to a platform service
      makes qnsc-kb's autoscaling affordable — a replica costs ~1 GB instead
      of ~4. Not urgent; clamav ships first
§15d  Why "start minimal and autoscale" is only half right: correct for replica
      and node count, expensive for pod size, because the scheduler packs on
      requests and an HPA cannot rescue an under-sized pod
§15e  Second tier of levers (~$520), the structural lever (four of seven
      products do not exist yet), and an explicit stop line

sixth pass — the remaining cost levers
§5b   REOPENED. The scheduled-shutdown refusal conflated compute with databases.
      The 2026-09-13 incident was a stopped RDS instance needing a human and
      5-10 minutes; a Deployment scaled to zero returns in 60-90 seconds. Split:
      dev databases get Aurora Serverless v2 at 0 ACU, dev compute gets a KEDA
      cron scaler. ~$70/month
§14   Auto Mode's premium was stated as $12/month on ~$100 of nodes. Re-priced
      nodes are $468, so it is $56 — wrong by 4.7×. Decision unchanged, but it
      is now a real trade and should be re-made after §15d
§15e  NEW. Every remaining lever, ranked and compounded: ~$1,010 → ~$620-700.
      Only two clear the bar. Plus the aggressive option — deleting the
      permanent dev environment in favour of preview environments, ~$400

fifth pass — the database line, and the cost case
§15   RE-PRICED against ap-southeast-1 and rebuilt bottom-up from the live
      OpenTofu allocations. The old model used us-east-1 rates and allowed no
      node overhead. Result: EKS ~$1,010 against Fargate ~$1,016 at seven
      products — a wash, not $220. **Cost is removed as a decision driver**;
      three qualitative drivers remain and the case is weaker than first stated
§5    The database row splits by ENVIRONMENT as well as size. rova and qnsc-kb
      dedicated in prod; everything else shared; all of dev shared. Decided on
      RESTORE GRANULARITY — snapshots and PITR are per instance, not per
      database — after the $89 saving turned out to be $40 against an honest
      baseline
§5d   Rewritten around that split. The isolation table gains the restore row,
      which is the row that decides the design
§15b  −$239 becomes −$190, and carries a warning: §15's base is priced at
      us-east-1 for an ap-southeast-1 estate (+17-20%) and has no node overhead
      allowance. Bottom-up from the live OpenTofu allocations gives ~$1,000/month
      at seven products against ~$1,250 on Fargate — same direction, different
      absolutes. Also: August's $150.56 is not a baseline, because opshub prod
      and qnsc-kb prod are not running
```

## The decision

Move all products onto Kubernetes (EKS), delivered by ArgoCD, with **one Helm library chart**
and **one OpenTofu profile module** shared by every product. Keep OpenTofu for cloud
resources, Cloudflare for edge and object storage, Grafana Cloud for telemetry.

Three things drive it:

1. **Six products, ~15 services.** rova 3, opshub 3, kb 3, LMS 2–3, solodesk 2, AI dev kit 1,
   plus the `platform` namespace (§4c). That was premature at three products. It is not premature
   at fifteen services.
2. **Products differ in size and shape and will keep differing.** A platform that assumes one
   product shape will be worked around. This design makes size a value, not a fork.
3. **Preview environments.** Nearly free on ArgoCD and genuinely hard on ECS — and §11 records a
   second reason for them that has nothing to do with reviewing a UI.

**Cost is deliberately not on that list.** An earlier version made it driver 3 on the strength of a
$220/month advantage. Re-priced against ap-southeast-1 with a realistic node-overhead allowance,
the two platforms land within about $50/month of each other at seven products (§15). Break-even at
equal capability is a good result and no reason to stay — but it is not a reason to move, and a
justification that does not survive its own arithmetic should not be left standing in a document
that argues for honesty elsewhere.

### The third driver was withdrawn, and this is the record of it

An earlier version of this section said "three facts drive it, and only three", and the second was:

> "**The IC lab needs per-user ephemeral compute.** Spawning a sandboxed EDA environment per
> student, with quotas and a session lifecycle, is a scheduling problem. ECS has no answer;
> Kubernetes was built for it."

**That requirement no longer exists.** `VLSI-ACADEMY-LMS-PLAN.md` v0.3, dated **2026-09-12** — two
days before this document was first written — removed it:

> "**There is no laboratory plane. Practice is conducted in person, at the academy.** v0.2 proposed
> Zone D — browser-delivered EDA workstations, Slurm licence scheduling, per-student DCV sessions —
> and that is withdrawn in full. Students attend the academy and use its workstations."
>
> "**Withdrawn in v0.3 — all of it, not deferred.** Remote workstation (NICE DCV) · batch and
> licence scheduling · `learning-lab-broker` · licence-seat booking · cohort lab AMIs · Zone D
> tf-modules · RTL autograder…"

This document was written against a superseded version of the LMS plan. Everything that served the
lab — the `session` service kind, the `lab` node pool, the gVisor isolation design, and step 7 of
§17 — has been removed rather than deferred, on the reasoning in §4b: adding an architecture is
adding a service to a values file, so a capability with no user costs more to keep than to delete.
Unexercised design rots into wrong design.

**The decision survives, on the remaining drivers.** Two of the original three hold, and preview
environments were always independent of the lab. Cost briefly took the withdrawn lab's place as the
primary quantitative justification, and then did not survive being re-priced (§15) — so the
argument is now entirely qualitative: one chart across fifteen services, product shapes that will
keep differing, and a preview environment per pull request.

That is a weaker case than the document originally made, and it is stated plainly so that a reader
can weigh it rather than inherit it. It is still, on balance, the right call — but anyone who
concludes otherwise is not missing something.

### What does NOT drive it

Not cost — this is **more expensive** (see below). Not "nothing works" — the current ECS estate
is sound and was measured as such. Not language heterogeneity: containers already solved that,
and rova (TypeScript) runs beside qnsc-kb (Python) today.

### An honest record of the argument

This document argues *for* Kubernetes. The same analysis argued against it three times first,
and two of those objections were wrong:

* "The team would be learning it" — never checked, and false. k8s is the team's default from
  prior companies. ECS is the unfamiliar platform here, and every ECS-specific lesson
  (`task_definition` under `ignore_changes`, services pinned to stale revisions,
  `apply_immediately` silently deferring changes) transfers nowhere.
* "Migration cost" — anchored on migrating live products after being told to design fresh.

The objection that survives is that **nothing in the portfolio needs Kubernetes today**. That is
true, and it is outweighed by the drivers above — though less comfortably than when there were
three of them and one was a hard scheduling requirement. It is recorded here so the decision is not
re-argued from scratch in six months, and so that a reader who disagrees knows exactly which leg to
push on: measure §15 and the argument stands or falls there.

## What this does not change

Kubernetes does not replace infrastructure-as-code. Measured on rova's current stack: **4 of 17
module blocks are compute.** The other 13 — RDS, ElastiCache, secrets, DNS, tunnels, object
storage, observability, alarms — plus every raw resource (IAM roles, SNS topics, SQS queues,
EventBridge schedules) stay in OpenTofu. Anyone who says k8s replaces Terraform is selling
something.

## 1. Repositories: 19 → 13

Nineteen repositories exist today.

```
PRODUCTS (7)   rova · opshub · qnsc-kb-backend · qnsc-kb-frontend
               solodesk · lms · ai-dev-kit
PLATFORM (4)   infra · tf-modules · gitops · ci
SHARED (2)     app-platform · docs
```

**qnsc-kb stays split across two repositories, deliberately.** rova and opshub are monorepos and
qnsc-kb is not, which looks like an inconsistency to fix and is not one: the split follows
ownership. `qnsc-kb-backend` and `qnsc-kb-frontend` belong to a team member, and repository
boundaries that match who owns what are worth more than uniformity for its own sake. A future
reader comparing the three products will notice the difference — this paragraph exists so they
leave it alone.

Nothing in this design depends on it. The platform sees services, not repositories: the kb
frontend deploys to Cloudflare Pages and the backend's three services come from its own repo,
which the library chart handles identically whether they share a checkout or not.

`gitops` is new and load-bearing: the Helm chart plus the ArgoCD app-of-apps. The name is deliberate — an earlier draft called it `delivery`, which reads as a business noun in a semiconductor company and needed explaining every time. `gitops` says what is inside to anyone who has used ArgoCD or Flux, and it describes the pattern rather than the tool, so it survives a change of either. It is the single
source of deployment truth — which also makes required reviews on it a production access control
(§10b), and makes the chart's own version a thing that must be pinned and promoted (§11c).

Feature flags need no repository and no workload — they are a SaaS subscription with an
OpenFeature SDK in front of it (§4c).

Retire or fold in: `solo-desk-mockup`, `Logo_QNSC_v31`, `mcp-tools`, `qnsc-landing`,
`ceo-suite`, `tactile-ledger-flow`, `vlsi_deep_training`.

**A monorepo was considered and decided against — see §14.** It would remove the
publish-then-consume tax on shared code, it costs one to two weeks, and it has no bearing on this
platform: the chart deploys images, not repositories. Every repository above stays where it is.

## 2. Accounts and clusters

```
ONE account (608983206583) to start
  ├── EKS cluster "dev"   in runtime-dev VPC   10.90.0.0/16
  └── EKS cluster "prod"  in runtime-prod VPC  10.91.0.0/16
namespace per product              rova · opshub · kb · lms …
```

**Separate clusters for dev and prod is not negotiable. Separate AWS accounts is deferred.**

One component is deliberately exempt, and saying so here keeps the claim honest: **ArgoCD reaches
both clusters by design.** §5b puts it in prod and has it manage dev remotely, which is the
conventional hub-and-spoke arrangement and is how a deployer has to work — but it means the
isolation below is "no shared control plane *except the deployer*", not "no shared anything". The
$10–15/month that arrangement saves is not the reason to accept it; being the only component with
credentials on both sides makes ArgoCD's own RBAC and its repository access the thing to review
carefully.

The clusters matter because namespace-only separation shares a control plane, a CNI, and every
cluster-scoped resource — a bad admission webhook or a CRD upgrade reaches production. $73/month
buys real isolation and it is the cheapest isolation available.

Separate accounts would be better, and the reason is concrete rather than theoretical. On
2026-09-13 these commands ran minutes apart from one credential set:

```
aws rds delete-db-instance --db-instance-identifier rova-develop
aws rds delete-db-instance --db-instance-identifier rova-prod
```

In one account the only thing between a typo and production is the string typed. In separate
accounts dev tooling *cannot* reach prod — not "should not", cannot. Add credential-compromise
containment, quota isolation, and the fact that single-account dev+prod is a routine SOC 2
finding, and accounts are free.

**It is deferred because of a dependency, not a doubt.** QNSC is a member account in TrueIDC's
organisation `o-cnvpmom3os` (payer `033086823579`), and only the management account can create or
invite members. That puts someone outside this team on the critical path at step 1.

Worth stating plainly, since it caused confusion: **a second account does not mean leaving the
organisation.** An organisation has one payer and many members; both QNSC accounts would sit
inside TrueIDC's org, both under consolidated billing. Two accounts also means two root users,
which is unremarkable — hardware MFA, no access keys, never used, and already covered by the
`qnsc-root-api-activity` and `qnsc-root-console-login` rules in `security-baseline`.

**Split when SOC 2 requires it or a near-miss makes it urgent.** Doing it later is a known
migration; blocking the platform on someone else's ticket queue is a worse trade than the
isolation is worth today.

Node pools, via Karpenter or EKS Auto Mode:

| pool | capacity | purpose |
|---|---|---|
| `general` | **Spot**, diverse instance families | all workloads, **system pods included** |
| `ondemand` | small floor | one replica of each public `http` service (Axis 6, `capacity: mixed`) |
| `amd64` | Spot, small, scales to zero | clamd only (§4c) — the estate's one amd64 workload |

**There is no dedicated on-demand system pool, and an earlier version of this table specified
one.** It said `system | on-demand, 2 small | CoreDNS, ArgoCD, Alloy, External Secrets` — two
on-demand nodes per cluster, which §15's bottom-up model never priced, because it folds system
workloads into the general request pool. The two sections disagreed and this resolves toward §15.

Every one of those workloads survives a Spot reclaim: ArgoCD and External Secrets are reconcilers
that restart harmlessly, Alloy is a DaemonSet that follows nodes, and CoreDNS is two replicas
behind a PodDisruptionBudget. **Instance-family diversity plus topology spread is stronger
protection than two on-demand nodes**, because what actually takes out a Spot workload is a
correlated reclaim across one capacity pool, and diversity is the only defence against that.

Avoids introducing roughly **$100–140/month** the earlier table implied.

**Fargate profiles are excluded, not overlooked.** Fargate for EKS does not support DaemonSets,
which eliminates Alloy — and Alloy is one of the main reasons to do this at all (§8).

**The alternative that would remove the floor, priced.** Two control planes are $146/month and
$73 of that is dev — by §15e's figures the single largest line in the bill and the only one no
lever touches. **vCluster** would run dev as a virtual cluster inside the prod cluster: its own API
server (a pod), its own CRDs, its own RBAC, sharing nodes and CNI. That is most of what this
section wants, for roughly **$100/month less** once dev's duplicated system overhead is counted.

Not taken. It shares the kernel and the CNI, so a node-level or CNI-level failure still crosses the
boundary — and more decisively, it is a new abstraction to learn and debug for a team of three, and
a fourth entry in §2b's version-pinning list. **Recorded with its number so the option is weighed
rather than forgotten**, and revisit if the control-plane line ever becomes the thing standing
between this platform and affordable.

**Open decision — Auto Mode or Karpenter on EC2.** Auto Mode has AWS manage nodes, add-ons and
upgrades at a per-pod premium; Karpenter gives control at the cost of owning it. See §14.

## 2b. Cluster upgrades

EKS ships a new Kubernetes minor roughly three times a year, and each leaves standard support
after about fourteen months, after which AWS charges extended-support rates. **Auto Mode manages
nodes; the control plane version is still ours to bump.**

This section exists because upgrade work has no deadline until it has a bill, and it is the
first thing a two-person team defers.

```
cadence     one minor per quarter, always N-1 or newer, never N-3
order       dev cluster → observe for one week → prod cluster
window      prod during the existing Mon 04:30-06:00 UTC maintenance window
```

Before each upgrade, check API compatibility for the three things that pin Kubernetes versions:
**ArgoCD, Alloy, External Secrets Operator.** (Policy is ValidatingAdmissionPolicy, which is
in-tree and therefore not a fourth — see §10.) A removed API in a controller is the
usual way an upgrade fails, and it fails at reconcile time rather than at upgrade time — the
cluster comes up and workloads stop being managed, which is quieter and worse.

Record the current version and the support end date somewhere a human reads. The
`alerting_health` check is the natural home: a cluster within ninety days of end-of-support is a
finding, not a surprise.

## 3. Networking, and one prerequisite

EKS provides a managed control plane and **nothing network-shaped**. The VPC, subnets, NAT,
routing and DNS remain exactly as they are in `runtime-dev` and `runtime-prod`.

**Prerequisite, before any cluster exists.** The AWS VPC CNI assigns every pod a *real subnet
IP*, and nodes reserve them in blocks. Current sizing:

```
VPC              10.90.0.0/16      65,536 addresses
private subnets  10.90.10-12.0/24  3 × ~251 usable ≈ 750 pod IPs cluster-wide
```

At fifteen services with replicas, plus Alloy on every node, plus system workloads, that is not
enough — and exhaustion presents as pods stuck in `ContainerCreating` with no obvious cause.

* Resize private subnets `/24` → `/20` (~4,000 each). The `/16` is nearly empty; the space is
  free today and requires recreating subnets under load later.
* Enable **prefix delegation** on the VPC CNI.
* `runtime-prod` (`10.91.0.0/16`) needs the same treatment.

### The S3 gateway endpoint, which should exist already

ECR image layers are served from S3, so every image pull currently crosses fck-nat and is billed
per gigabyte. That is not a hypothetical: **August's ECR bill was roughly 94% data transfer**, which
is what moved the build cache off the ECR `registry` backend on 2026-09-13 (§11). The cache moved;
the pull path did not.

```
S3 gateway endpoint       $0/month — removes most ECR pull transfer from NAT
ECR interface endpoints   $14.60/month for ecr.api + ecr.dkr — only if NAT
                          transfer still exceeds that afterwards
```

A gateway endpoint is free and has no operational surface. Kubernetes makes this worse than ECS
did — nodes pull images on every scale-out and every Karpenter consolidation, not only on deploy —
so this belongs in step 1 of §17, ahead of the cluster.

### No load balancer, but yes to Gateway API

An earlier draft of this document said "no ingress needed" and put routing in cloudflared's
config. That was wrong, and wrong in a way worth recording: seven products' routes in one
ConfigMap makes ingress a **shared mutable file**, which is the opposite of the per-namespace
ownership everything else here depends on — and it puts half the routing in Cloudflare rather
than in the repository ArgoCD reconciles.

The correct split is that Cloudflare Tunnel replaces the **load balancer**, not the routing
layer:

```
internet
  → Cloudflare edge          WAF · rate limit · Turnstile · Access · TLS
  → tunnel                   outbound only — no public IP, nothing to scan
  → cloudflared × 3          ONE catch-all rule → Gateway. Configured once, never edited.
  → Gateway (in-cluster)     Gateway API — ordinary Kubernetes
  → HTTPRoute per namespace  rova owns rova's route, in git, reconciled by ArgoCD
  → Service → pod
```

Not needed: ALB/NLB (~$16/month each), AWS Load Balancer Controller, `Ingress` resources,
cert-manager. Cloudflare terminates TLS, so certificates are not a cluster concern.

**One cloudflared Deployment per cluster, three replicas** — not one per product. Per-product
tunnels would be 7 × 2 = 14 pods and roughly a gibibyte of RAM proxying, with no benefit once
Gateway does the routing. Cloudflare load-balances across connectors, so three replicas is HA.

This arrangement resolves three problems in one move: routes become per-product resources in
git, the tunnel config stops changing, and preview environments get a hostname mechanism (§11)
instead of needing per-PR tunnel edits.

Use **Gateway API**, never `Ingress` — Ingress is effectively frozen and Gateway is where the
ecosystem went. And never an ALB behind a tunnel: that pays for a load balancer the tunnel
bypasses.

### The alternative, honestly

`ALB → Gateway` is the conventional design and needs no explanation to anyone who has run
Kubernetes. It costs ~$32/month for two ALBs plus LCU charges, and it accepts a public
internet-facing endpoint.

Tunnel is chosen over it because: this organisation already runs tunnels on ECS so it is not new,
both shared ALBs are already at `enable_alb = false` by deliberate choice, Cloudflare already
provides the WAF and rate limiting an ALB would duplicate, and **no inbound surface** is the
strongest property of the current architecture. With Gateway API in front of the pods, the
Kubernetes side is entirely conventional regardless.

If familiarity ever outweighs those, `ALB → Gateway` is a good design and the swap touches only
what is upstream of the Gateway. Nothing about HTTPRoutes, services or products changes.

Two concrete triggers exist rather than a vague preference: a **public gRPC API**, which an ALB
terminates natively and a tunnel makes fiddly (§4d), and a **latency SLA** tighter than the tunnel's
5–15 ms overhead (§9j).

## 4. The Helm library chart: service kinds

The chart knows what a *service* is. A product declares as many as it needs, so a monolith is
three services and a product that later splits into eight is still the same chart.

| kind | renders |
|---|---|
| `http` | Deployment, Service, HPA, PDB, tunnel route |
| `worker` | Deployment, HPA — no Service, no ingress |
| `job` | Job as an **ArgoCD PreSync hook** |
| `cron` | CronJob |

Migrations are a `job` running as `argocd.argoproj.io/hook: PreSync`, **not** a Helm
`pre-upgrade` hook. With ArgoCD owning the lifecycle, Helm hook failure semantics and ArgoCD's
sync state disagree, producing releases that are "failed" in Helm and "Synced" in ArgoCD.
PreSync blocks the sync on migration failure, which is the desired behaviour.

Set an explicit timeout — 600s — because the default will kill a slow migration part-way, which
is the worst possible moment. Recovery is already covered by the expand-and-contract rule (§13):
a half-applied migration leaves a forward-compatible schema, so re-running the sync is safe.
Stating that here because "the migration died halfway through" is otherwise a panic rather than a
retry.

## 4b. Any architecture, expressed as a composition

Size presets answer *how big*. They do not answer *what shape*, and the products will not agree
on shape: rova and opshub are modular monoliths, the AI dev kit is one service, clamd is a
container nobody here wrote, and the LMS is a video pipeline. A platform that assumes one
shape gets worked around, and the workarounds become the seven copies this design exists to
prevent.

So the chart's primitive is a **service**, with four axes, and an architecture is a composition of
services rather than a template to pick.

### Axis 1 — kind

| kind | renders |
|---|---|
| `http` | Deployment, Service, HPA, PDB |
| `worker` | Deployment, HPA — no Service |
| `job` | Job as an ArgoCD PreSync hook |
| `cron` | CronJob |
| `grpc` | Deployment, **headless** Service, GRPCRoute, HPA, PDB — see §4d |
| `realtime` | Deployment, Service, HTTPRoute, **PDB always**, long drain — see §4e |

### Axis 2 — exposure

```yaml
expose: public      # tunnel route, reachable from the internet (WAF, rate limit in front)
expose: protected   # tunnel route + Cloudflare Access — reachable anywhere, by our people only
expose: internal    # ClusterIP only, service-to-service inside ONE namespace
expose: cluster     # ClusterIP reachable from every product namespace — platform services
expose: none        # no Service at all (workers, jobs)
```

`protected` is the state most of this estate needs and the one most easily got wrong. opshub is
an internal operations tool and the AI dev kit is for the
team — none should be on the public internet with only a WAF in front, and none should be
`internal` either, because people need them from a laptop.

`cluster` exists because §10 makes namespaces default-deny, and a shared internal service
therefore needs a NetworkPolicy exception in *every* consuming namespace. Written by hand, seven
times, that exception is how default-deny quietly stops meaning anything. As an exposure level it
renders once: a Service, plus ingress from any namespace labelled `qnsc.vn/tenant=product`, plus
the matching egress allow on the product side. See §4c for what uses it.

**Cloudflare Access** solves it: the tunnel route is fronted by a zero-trust policy backed by
Entra, which both rova and opshub already authenticate against. No VPN, no bastion, no public
exposure. Getting this wrong in the other direction — marking an internal tool `public` because
it needed to be reachable — is how internal admin UIs end up indexed.

This is what makes microservices expressible: eight `http` services, one `public`, seven
`internal`. Service-to-service uses cluster DNS —
`http://orders.rova.svc.cluster.local:3000` — with retries and timeouts in the client library.
**No service mesh** until there is a named reason; fifteen services does not need mTLS mesh.

### Axis 3 — resources, including GPU

```yaml
resources:
  cpu: 500m
  memory: 1Gi
  gpu: 1            # optional; schedules onto a GPU node pool
```

Nothing needs a GPU today — qnsc-kb computes e5 embeddings in-process on CPU and the AI dev kit
calls OpenRouter. The axis exists so that moving embeddings to a dedicated model server, or
self-hosting inference for the LMS, is a values change and not a platform decision.

### Axis 4 — image

```yaml
image:
  repo: 608983206583.dkr.ecr.…/rova-api     # built here
# or
  repo: flagsmith/flagsmith                  # built by someone else
  tag: "2.x"
```

Third-party containers are ordinary services. clamd needs no repository and no bespoke handling —
it is a values file with an upstream image (§4c).

### Axis 5 — architecture

```yaml
arch: arm64     # default
arch: amd64     # only when an image has no arm64 build
```

Graviton is roughly 20% cheaper for equal work, and the estate is already mostly there: rova and
opshub build arm64 and were verified as doing so on 2026-08-17. qnsc-kb is the exception, and the
exception is currently expressed in the wrong place — `ci/scripts/stack_conformance.py` carries
`"api::cpu_architecture": "qnsc-kb is x86 — clamav/clamav ships no arm64 tag"`, so one sidecar
pins an 8 vCPU / 24 GiB product to the more expensive architecture.

Making `arch` a per-service field rather than a per-product one is what dissolves that: clamav
becomes one `amd64` service and everything around it moves to `arm64`. §4c does exactly this.

### Axis 6 — capacity

```yaml
capacity: spot        # default
capacity: ondemand    # interruption is expensive or recovery is slow
capacity: mixed       # on-demand floor, Spot above it
```

Spot is not a cluster-wide setting because the right answer differs per service, and qnsc-kb
already reasons about it correctly today: *"The api stays OFF Spot even after go-live: a Spot
interruption is a dropped request and a broken response mid-answer. The worker takes Spot
deliberately — Celery redelivers an interrupted task, so an interruption costs time rather than
work."* That reasoning is per service. The field carries it instead of a comment.

Three things must hold for Spot to be safe, and none is automatic:

```
instance families   a wide list — more capacity pools means fewer interruptions
drain               terminationGracePeriodSeconds plus a preStop sleep, completing
                    inside the 120-second Spot interruption notice
floor               `capacity: mixed` for public http, so an interruption storm
                    cannot take every replica at once
```

### Axis 7 — scaling

```yaml
scaling:
  type: rps | queue | cpu | cron | none
  min: 2
  max: 6
  target: 200
```

**KEDA, not raw HPA, and from day one rather than later.** CPU-target autoscaling is the wrong
signal for almost everything here: Node and Python services on this estate are IO-bound, so CPU
never reaches the target, the HPA never fires, and the compensation is a permanently
over-provisioned replica floor. qnsc-kb's prod values say `enable_autoscaling = false` with a
`cpu_target_pct = 60` sitting unused beside it, which is that problem already visible.

One controller answers four separate needs this document otherwise defers:

```
type: rps      Prometheus request-rate trigger — the correct signal for `http`
type: queue    SQS depth or Celery queue length — the correct signal for `worker`
min: 0         scale to zero: dev workers, and prod workers between batches
type: cron     the scheduled shutdown §5b defers — built in, not a later project
```

### `singleton` — found by building the chart, not by designing it

Task 1.7 of `implementation-plan.md` wrote real values files for rova, opshub and
qnsc-kb against the eight axes. One product could not be expressed:

> "max_count stays 1 while Celery beat rides in this task — **two replicas would double every
> scheduled job.**" — `qnsc-kb-backend/infra/live/prod/main.tf`

Celery beat holds no lock and cannot take one, so it must never have two replicas — **including
for the few seconds a RollingUpdate overlaps the old pod and the new one.** No combination of
`scaling` expressed that, because `scaling.max: 1` still permits an overlapping rollout.

```yaml
singleton: true     # replicas 1 · no scaling · strategy: Recreate
```

The chart **fails** on `singleton` together with `scaling.max > 1` rather than silently
preferring one, because the failure mode of getting it wrong is every scheduled job running
twice — which presents as a data bug, not a deployment bug, and would be hunted in the wrong
place for a long time.

**The distinction is narrower than "runs scheduled work", and the estate proves it.** rova's
worker carries seven `@Cron` relays and scales to six safely: `AbstractOutboxRelay` uses
`SELECT … FOR UPDATE SKIP LOCKED`, and `ExclusiveJob` holds a cross-pod lock for the snapshot and
cleanup crons. Those replicas divide work rather than duplicating it. `singleton` is only for a
scheduler that holds no lock and cannot take one.

Splitting beat out of the worker is also what finally lets qnsc-kb's worker scale horizontally —
something the ECS module could not express, and which the same file records as a known
prerequisite.

§5b's "add it later, not never" stays true for the *policy*. The component should not be later:
retrofitting KEDA across fifteen services means unwinding fifteen HPA configurations, and that is
strictly more work than starting with it.

### Axis 8 — SLO

```yaml
slo:
  availability: 99.5
  latency: { p99: 500ms }
```

Renders the Grafana recording rules and multi-window burn-rate alerts for that service (§9e). The
axis exists because of a measured failure mode: every alarm topic in this account had zero
subscribers for weeks while "alarms are configured" was true. An alert that the chart renders
alongside the Deployment cannot be forgotten, because it is not a separate act of remembering.

### The compositions

| architecture | expressed as |
|---|---|
| single service | one `http` |
| modular monolith | `http` + `worker` + `job` |
| microservices | N `http`, one `public`, rest `internal` |
| event-driven | one `worker` per consumer + `queue.sqs` in the profile |
| batch / ETL | `cron` services |
| model serving | `http` with `resources.gpu` |
| third-party app | `http` with an upstream image |
| shared platform capability | `http` with `expose: cluster`, in the `platform` namespace (§4c) |
| internal gRPC API | `grpc` with `expose: internal` (§4d) |
| live updates, one direction | `http` with SSE — no new kind needed (§4e) |
| bidirectional realtime | `realtime` + Valkey backplane (§4e) |
| gRPC service with a public REST edge | `grpc` internal + `http` gateway service, `expose: public` |

Nothing in that table requires a new chart, a new module, or a fork. **Adding an architecture
means adding a service to a values file.** That is the property being asked for, and it is the
only reason a single chart survives seven products.

### The same discipline on the OpenTofu side

`product-profile` must not carry a fixed list of capabilities either, or the flexibility stops at
the cluster boundary. Capabilities are a set, each defaulting to absent:

```hcl
postgres = { mode = "none" | "shared" | "dedicated", extensions = [...] }
cache    = { mode = "none" | "shared" | "dedicated" }
storage  = { r2_buckets = [...] }
queue    = { sqs = bool }
search   = { opensearch = bool }        # absent today; added when first needed
keyvalue = { dynamodb = bool }          # same
```

A product with no database sets `mode = "none"` and gets no RDS, no secret, no IAM grant, no
alarms. Adding OpenSearch later means adding one optional block to the module — not a second
module, and not a copy of the first.

## 4c. Platform services: the category this design was missing

Three things in this portfolio are neither products nor infrastructure. They are **capabilities
that products consume**: ClamAV as soon as qnsc-kb migrates, and — anticipated in Axis 3 — a shared
embedding or inference server if the LMS or qnsc-kb ever stops computing e5 in-process.

Earlier drafts also put a self-hosted Flagsmith here, which is what made the category visible in the
first place. It has since been removed — see below — but the category survives it, and a category
with no name grows a different convention each time it is used.

```
namespace `platform`, one per cluster
  clamd        malware scanning          expose: cluster   arch: amd64
  (feature flags are NOT here — see below)
  embeddings   e5-large-instruct         expose: cluster   — see below
```

These are ordinary services in the library chart. Nothing about them is special except the
namespace they live in and the `cluster` exposure level that lets product namespaces reach them
without hand-written NetworkPolicy exceptions.

### Feature flags are NOT a platform service — they are a SaaS subscription

A self-hosted Flagsmith was the original second member of this category, and it is removed.

**Decision: OpenFeature SDK in every service, ConfigCat as the provider.** Nothing runs in the
cluster, nothing appears in §2b's upgrade list, and no database is added to §5d's shared instance.

The reasoning is the one this document uses four other times — §7 refuses Crossplane, §9i refuses a
self-hosted LGTM stack, §4b refuses a service mesh, §6b refuses Kafka and NATS. Each refusal is the
same trade: **with three engineers, a component must earn its upgrade path.** A database-backed web
application with an admin console, run to store roughly twenty booleans, does not earn it.

```
OpenFeature   the vendor-neutral SDK. Applications import @openfeature/server-sdk,
              never a vendor SDK. One line per service names the provider.
ConfigCat     the provider. Free tier, a UI other departments can use, and paid
              pricing that does not scale with END-USER counts — which matters
              because rova, opshub and qnsc-kb are B2B.
```

Flagsmith Cloud would serve equally well; ConfigCat wins on the pricing shape above the free tier.
**LaunchDarkly is excluded** — the best product in the category, priced per seat *and* per
monthly-active-context, which is the wrong shape for a B2B estate run by three people.

**One rule while the §18 residency question is open: server-side evaluation only.**

```
server-side SDK (rova · opshub · qnsc-kb)   the SDK downloads the ruleset and evaluates
                                            IN THE POD. User context never leaves Vietnam.
browser / mobile SDK                        sends user context to the vendor — a
                                            cross-border transfer of personal data, and
                                            squarely inside the Decree 13/2023 question
```

So a flag is evaluated in the API and shapes the response. Nothing calls ConfigCat from the React
frontends or from solodesk until counsel has answered.

**The exit, and it is cheap because OpenFeature is there from the start:**

```
the bill matters (§12b)          → flagd in this namespace, ~1 day
residency answer is restrictive  → flagd, or a flags page in opshub, 2-3 days
```

`flagd` is the OpenFeature project's own daemon: a ~50 MB Go binary that reads flag definitions
from a ConfigMap and serves evaluations in-cluster. No database, no UI — flags become a reviewable
diff in `gitops`, which is the §11 property. It is the right answer the moment a UI stops being
worth a subscription, and the swap is one provider line per service.

**And one discipline that keeps both exits cheap:** twenty flags migrate in an afternoon, two
hundred do not migrate at all. Every flag carries an owner and a removal date, and a flag whose
feature is permanent gets deleted. Put the sweep beside §12c's quarterly orphan check.

### ClamAV: one service, not a sidecar per task

This is the first real user of the category, and the decision is already recorded in the code
being migrated. `qnsc-kb-backend/infra/modules/stack/main.tf`:

> "each task runs its own copy, because clamd is reached over localhost and awsvpc scopes that to
> a task… If the API ever scales past a couple of tasks, replace this with one clamd behind
> Service Connect rather than paying ~2 GB per task."

and `qnsc-kb-backend/infra/live/prod/main.tf`:

> "clamd is per TASK, so at max_count 6 this is up to **12 GB of duplicated signature database** —
> the point at which one clamd behind Service Connect becomes the cheaper shape."

The sidecar was the right call on ECS, where awsvpc scopes localhost to a task and the alternative
is Service Connect. On Kubernetes the alternative is a Service name, so the condition those
comments set has been met by the migration itself.

Four reasons, of which only the first is about money:

**The signature database is the entire cost, and it does not scale with anything useful.** clamd
loads roughly 2 GB resident before it answers a single request, so the estate pays that per
replica rather than per unit of scanning:

```
per-task    kb prod api 6 × 2 GB = 12 GB · kb prod worker 1 GB · kb dev ≈ 3 GB
            plus the same again for every future product that accepts uploads —
            rova attachments, LMS submissions, solodesk
shared      prod 2 × 2.5 GB = 5 GB · dev 2.5 GB.  Flat. Independent of replica count.
```

**The sidecar provides no isolation to trade away.** It is `essential = true`, so a clamd crash
kills the whole task. Per-task clamd is correlated failure with duplicated memory, not a blast
radius. Two replicas behind a PodDisruptionBudget are strictly more available than an essential
sidecar.

**It has already caused an outage, and the mechanism is duplication.** From the same file:

```
ERROR: Database test FAILED.  ...  Update failed.
socket found, clamd started.
```

clamd came up only on the runs where the signature *update* had failed, because the older,
smaller database fit in the 1024 MiB it had been given and a successful update did not. Two tasks
killed for failed health checks before a third happened to get a failed update and went healthy —
roughly thirty minutes per worker deploy, presenting as intermittent rather than as a sizing
error. That failure mode requires freshclam to be running in N unmonitored places. One service is
one freshclam, one metric, one alert.

**It is what pins qnsc-kb to amd64.** The conformance exception in `ci/scripts/stack_conformance.py`
exists for the sidecar, not for the application. Splitting clamav out moves the api (1024/6144)
and worker (2048/6144) to Graviton and deletes a documented exception from three repositories.

```yaml
# gitops/platform/values.yaml
namespace: platform
services:
  clamd:
    kind: http
    expose: cluster
    arch: amd64                     # the only amd64 workload in the estate
    capacity: ondemand              # a 2 GB database reload is not worth Spot
    port: 3310
    resources: { cpu: 500m, memory: 2560Mi }
    replicas: { dev: 1, prod: 2 }
    slo: { availability: 99.9 }
```

Consumers reach it at `clamd.platform.svc.cluster.local:3310`. qnsc-kb already reads
`MALWARE_SCANNER_HOST` and `MALWARE_SCANNER_PORT` from the environment, so on the application
side this migration is one value.

**The latency objection does not survive the platform change.** The same comment notes the API
blocks on the scan in `_validate_source_bytes` and therefore "cannot wait on another service".
Measured against what the operation costs, the hop is noise:

```
localhost                       ~0.05 ms
cluster DNS, same AZ            ~0.5 ms   (with trafficDistribution: PreferClose, §3)
INSTREAM scan of a multi-MB PDF  100 ms – 2 s
```

The objection was never really about latency; it was about Service Connect being more machinery
than a sidecar. That trade reverses on Kubernetes.

### The embedding model is the second clamav, and the argument is identical

qnsc-kb's Dockerfile records that **"The e5-large-instruct ONNX session is ~1.5 GB resident"**, and
both the api and the worker load it — the api to embed the search query, the worker to embed
chunks. So the estate pays for the model per replica, exactly as it paid for the ClamAV signature
database per task:

```
prod today     api 2 replicas + worker 1        3 copies    4.5 GB
prod at HPA max (api max_count 6)               7 copies   10.5 GB
dev            api 1 + worker 1                 2 copies    3.0 GB

shared service prod 2 replicas · dev 1          flat        3.0 GB prod · 1.5 GB dev
```

**The steady-state saving is modest — about 1.5 GB. That is not the point.** The point is that a
qnsc-kb api replica currently costs ~1.5 GB of model before it serves a single request, which makes
horizontal scaling of the largest product in the estate expensive per replica. Extract the model and
a replica costs roughly 1 GB instead of 4, so autoscaling qnsc-kb becomes affordable rather than
something to avoid.

Axis 3 already anticipated this — *"The axis exists so that moving embeddings to a dedicated model
server… is a values change and not a platform decision."* This section is where that change lands,
and the reasoning is the one §4c exists for: **a large read-only artefact loaded per replica belongs
behind a service, not inside every pod that needs it.**

Not urgent. clamav ships first because it also unblocks Graviton (Axis 5); the embedding service
follows when qnsc-kb's autoscaling stops being theoretical, and §15d's measurement is what will say
when that is.

### Two things that must be decided rather than inherited

**Fail closed.** If clamd is unreachable, the upload is rejected with a retryable error. Failing
open means unscanned user documents enter the knowledge base, which removes the control while
leaving the reassurance — the worst of both. The availability cost is bounded by two replicas and
a PDB; the correctness cost of failing open is not bounded by anything. Clients need a short
timeout (5 s connect, 30 s scan) and one retry, so that a rolling restart is a blip rather than an
error surfaced to a user.

**Signature freshness is monitored, not assumed.** clamd's `VERSION` command returns the database
build date. Scrape it and alert when signatures are more than 24 hours stale. Stale antivirus is
worse than absent antivirus: it fails silently and it passes an audit.

### What was rejected

* **Building an arm64 ClamAV image.** It compiles on arm64, and doing so would remove the estate's
  only amd64 workload. It would also mean owning CVE patching for a security-critical image with
  two or three engineers. Isolating one service is cheaper than maintaining one image.
* **A third-party scanning API** (VirusTotal and similar). It ships customer documents to an
  outside party. Not acceptable for a knowledge-base product.
* **GuardDuty Malware Protection.** It scans S3 objects, and object storage here is Cloudflare R2
  (§7). Self-hosted ClamAV is correct *because* of the R2 decision, not in spite of it.

## 4d. Polyglot: what the platform actually requires of a service

A future product may be written in Go and may expose gRPC. Neither is a problem, but "neither is a
problem" is an assertion until the requirements are written down, so here they are.

### The contract

The platform asks a service for seven things, and not one of them is language-specific:

```
image        OCI, multi-arch (arm64 by default — Axis 5)
config       environment variables. No config files baked into images
health       an HTTP path, OR the gRPC health protocol (see below)
telemetry    OTLP to the Alloy gateway, with §9a's resource attributes set
identity     a Kubernetes ServiceAccount with an IRSA role
secrets      environment variables injected by ESO (§8)
contract     protobuf or OpenAPI, versioned, with breaking-change detection in CI
```

That list is the flexibility property, stated as a thing a reader can check. "Will the platform
support Go?" is answerable by reading it rather than by trying.

Note what is *not* on the list: a shared library. `app-platform` is TypeScript, so a Go product
cannot use `sanitizeString` or `platform-cache`. That is fine and it must stay fine — **the shared
thing is the contract, not the code.** A platform that requires its own library is a platform with
one language in it.

### Go needs nothing special, and is cheaper than what runs today

```
image         distroless or scratch, single static binary — single-digit MB against
              Node's ~150 MB and qnsc-kb's model-bearing image
memory        typically 20–80 MB resident, against Node ~150–300 MB and
              qnsc-kb's ~1.5 GB ONNX session
startup       milliseconds
arch          cross-compiles to arm64 with a build flag. No clamav-shaped exception (§4c)
```

Every one of those makes a Go service the *best* candidate for the aggressive settings elsewhere
in this document: `capacity: spot`, `scaling.min: 0`, and a low replica floor. Fast startup is what
makes scale-to-zero pleasant rather than a latency incident.

One consequence for §5: the size presets were sized against Node and Python. An XS preset is
generous for Go, and the answer is the one §15b already gives — measure with VPA in recommendation
mode rather than guessing a second time.

### gRPC: one genuine problem, and it is load balancing

Everything else about gRPC is ordinary. This part is not, and it is the failure that looks like
"we scaled to six replicas and one of them is at 100% CPU".

**gRPC is HTTP/2, so it multiplexes many requests over one long-lived connection. A Kubernetes
`Service` balances at L4 — per connection, not per request.** A client that opens one connection
therefore pins to one server pod for the life of that connection, and the other five replicas
receive nothing. Autoscaling on a metric that never rises makes it worse rather than better.

Three ways out, in the order this platform should try them:

```
1  client-side load balancing    headless Service (clusterIP: None) + DNS resolver +
                                 round_robin. Zero infrastructure. First-class in Go's
                                 grpc-go and fine in the other major clients.
2  L7 proxy at the Gateway       Envoy-based Gateway implementations balance gRPC per
                                 request. One hop, and only for traffic crossing the Gateway.
3  service mesh                  refused — see below
```

**Option 1, and §4b's "no service mesh until there is a named reason" survives this.** gRPC load
balancing is the most commonly cited reason to adopt a mesh, and it is a real one — but a headless
Service plus `round_robin` in the client solves it without a sidecar per pod, a control plane, or a
fourth entry in §2b's version-pinning list. The mesh remains unnecessary; the reason it is
unnecessary is now specific rather than assumed.

```yaml
services:
  pricing:
    kind: grpc            # renders Deployment, HEADLESS Service, GRPCRoute, HPA, PDB
    expose: internal
    port: 9090
```

`kind: grpc` differs from `kind: http` in exactly three renders: a headless Service, a `GRPCRoute`
instead of an `HTTPRoute`, and a gRPC health probe. **This is a payoff from §3's Gateway API
decision** — `GRPCRoute` is a first-class Gateway API resource, and `Ingress` could never express
gRPC routing properly. That choice was made for other reasons and pays here.

### gRPC health probes

Kubernetes has supported the gRPC health protocol natively since 1.24, so no `grpc_health_probe`
binary belongs in the image:

```yaml
livenessProbe:
  grpc: { port: 9090 }
```

§9j's discipline is unchanged and applies identically: liveness answers `SERVING` if the process is
up and checks nothing else; readiness may check dependencies.

### gRPC at the edge is the constraint — keep it internal

Service-to-service gRPC inside the cluster is unremarkable. gRPC *through Cloudflare Tunnel to the
public internet* is where the edge cases live: it needs gRPC enabled on the zone, `http2Origin` on
the connector, and bidirectional streaming through a proxied path is the part most likely to
disappoint.

**So: gRPC internal, REST/JSON or gRPC-Web at the edge.** That is the conventional shape anyway —
browsers cannot speak raw gRPC — and it avoids every one of those edge cases.

If a genuinely public gRPC API is ever required, that is **a second trigger for the `ALB → Gateway`
swap §3 already documents**, because an ALB terminates HTTP/2 and gRPC natively with no zone
configuration. §3 records that the swap "touches only what is upstream of the Gateway"; this is a
concrete reason it might be taken, alongside the latency trigger in §9j.

### Telemetry, with one honest caveat

OpenTelemetry instruments gRPC first-class in every language that matters, and trace context
propagates over gRPC metadata. Nothing in §9 changes.

The caveat is §9c's claim that **eBPF is the floor**. That claim is weaker for gRPC: decoding
HTTP/2 framing under TLS is harder than plain HTTP, and Go's eBPF instrumentation works through
uprobes on the Go runtime, which is sensitive to the toolchain version. So for a Go and gRPC
product, **SDK interceptors are the baseline and eBPF is the bonus** — the reverse of the rule for
everything else. Worth knowing before relying on golden signals that may not appear.

### Contracts: `buf`, and why it is the same control as §6b

A polyglot estate needs generated clients in more than one language, which makes the `.proto` a
shared artifact and therefore a thing that can drift:

```
buf lint        style and consistency
buf breaking    breaking-change detection against the main branch, in CI
buf generate    Go, TypeScript and Python clients from one source
```

`buf breaking` is the same control as the EventBridge schema registry in §6b, aimed at the same
failure: **a producer and a consumer disagreeing about a message shape, with no error state to
observe.** §6b's failure #2 was exactly that — a filter matching `eventType` values the codebase
never emitted — and it was invisible for the same reason a proto drift would be.

Protobuf definitions live in their own repository or in a `contracts` directory, versioned and
tagged. Not inside whichever product happens to have written them first.

### Where a Go product's repository goes

Every product has its own repository today and §14 keeps it that way, so a Go product raises no
question at all: it gets one too. **Its own toolchain, its own module graph, and no shared build
cache with the JavaScript products** — the same reasoning that keeps solodesk separate, and the
reason it would stay separate even if §14 were revisited.

The `contracts` repository is what keeps it connected, which is the correct coupling — a schema
rather than a build system.

## 4e. Realtime: WebSocket and SSE

WebSocket works on this architecture, and the path is already in place: Cloudflare proxies
WebSocket natively, cloudflared carries it, and `HTTPRoute` handles an HTTP/1.1 Upgrade like any
other request. Nothing in §3 needs to change.

**The problem is not the path. It is that several cost decisions in this document are actively
hostile to long-lived connections, and silently so.** A WebSocket service deployed on the defaults
below would work in dev, pass review, and drop every connected client several times a day in
production.

```
capacity: spot        a Spot reclaim gives 120 seconds and drops every connection on the pod
consolidation         Karpenter bin-packs by requests and drains nodes eagerly (§5b)
grace period          the default 30 seconds is far too short to drain connections
scaling on CPU        a WebSocket server is connection- and memory-bound, never CPU-bound,
                      so the HPA never fires while memory climbs
scaling.min: 0        scale-to-zero and a persistent connection are incompatible by definition
```

### Ask for SSE first

Most requirements described as "we need WebSocket" are one-directional: notifications, live
progress, a document that updates, a dashboard that ticks. **Server-Sent Events covers all of those
and costs nothing to operate.**

```
SSE          plain HTTP, no Upgrade, passes through Cloudflare, the Gateway and every proxy
             unchanged. Automatic browser reconnection with Last-Event-ID.
             Works with `kind: http` exactly as written.
WebSocket    required only when the CLIENT must push at low latency — collaborative
             editing, chat, live cursors, a terminal session
```

qnsc-kb's ingestion progress, rova's notifications and opshub's job status are all SSE-shaped. Reach
for WebSocket when a client genuinely writes, and not before — the difference is a `kind: http`
service against everything in the rest of this section.

### `kind: realtime`

When WebSocket is genuinely required, it is a service kind with different defaults rather than an
`http` service with hand-tuned overrides — the §5 rule applies: if a preset does not fit, the
preset gains a field.

```yaml
services:
  live:
    kind: realtime          # Deployment, Service, HTTPRoute, PDB, and the defaults below
    expose: public
    capacity: ondemand      # NOT Spot. A reclaim drops every connection on the pod
    scaling:
      type: connections     # KEDA on a connection-count gauge, never CPU
      min: 2                # never 0
      max: 8
    drain:
      terminationGracePeriodSeconds: 300
      preStop: close-frames # stop accepting, send close, let clients reconnect elsewhere
```

**The drain behaviour is the part that must be written, not configured.** A pod being removed
should stop accepting new connections, send a WebSocket close frame with a reconnect hint to each
client, and then exit — rather than being killed with connections open. Clients reconnect through
the Gateway onto a surviving pod and the user sees a flicker instead of an error. Without it, every
deploy, every consolidation and every scale-in is a visible outage to whoever is connected.

`PodDisruptionBudget` is mandatory at every size for `realtime`, including XS. §5's preset table
turns PDB off below size M, and that default is wrong here for the same reason Spot is.

### The fan-out backplane, and a fourth reason Valkey stays

Two clients on two pods cannot reach each other without a backplane: if A is connected to pod 1 and
B to pod 2, pod 1 must publish somewhere pod 2 is listening.

```
Valkey pub/sub       already provisioned (§5d). Socket.IO's redis adapter and every
                     equivalent library target it. Nothing new to run.
NATS                 a better fit technically, refused in §6b for consistency reasons
                     that still hold
Postgres LISTEN/NOTIFY   works, but puts the realtime path on the database's connection
                     budget, which §5d is already managing carefully
```

**Valkey.** This is the fourth use of the instance §5d keeps — Celery broker, shared cache, rate
limiting, and now the realtime backplane — and it further weakens the earlier draft's suggestion
that Redis could be removed.

### Cloudflare specifics

```
WebSocket through the tunnel   supported. No configuration change to §3's catch-all rule.
idle connections               send an application-level ping every ~30 seconds. Required
                               regardless of Cloudflare — intermediaries drop idle sockets.
Cloudflare Access              works with WebSocket, so `expose: protected` is available
                               for an internal realtime tool
```

### Observability is a different shape

A WebSocket connection produces one span and then hours of silence, so §9's request-oriented
defaults measure nothing useful. The signals that matter:

```
connections_active          gauge, per pod — also the KEDA scaling metric
connection_duration         histogram — a falling p50 means something is killing sockets
reconnect_rate              the leading indicator of a bad deploy or a drained node
messages_sent / received    rate, by type
```

And the SLO in Axis 8 is shaped differently: **connection success rate and reconnect rate**, not
request latency. A `realtime` service that reports 99.9% availability on HTTP probes while dropping
every socket every twenty minutes is reporting the wrong number.

### The alternative worth knowing about

**Cloudflare Durable Objects**, for a *new* product rather than a migration. A Durable Object gives
one authoritative coordination point per room, document or session at the edge, and the WebSocket
Hibernation API holds connections open without paying for idle compute — which is the expensive
part of running realtime on always-on pods.

It is a different programming model and it is Workers-only, so it is not a thing to retrofit onto
rova or opshub. But if the realtime product is greenfield and TypeScript, it removes the entire
contents of this section: no backplane, no drain choreography, no on-demand replica floor. Worth
comparing before defaulting to pods.

## 5. Size presets

Products pick a preset and override individual fields. The preset exists so a new product starts
sane, not so it stays boxed in.

### "Size" means criticality, not footprint — and rova proves it

Read the table below and notice what is actually in it: replica floors, PodDisruptionBudgets,
database dedication, Multi-AZ, node pool. **Every row is an availability property. Not one is a
resource size.** Resource size lives in Axis 3 (`resources: { cpu, memory }`), where it belongs,
because it is a per-service measurement rather than a per-product category.

rova makes this concrete and is the reason it is worth stating. It is **size L and the smallest
workload in the estate**:

```
rova prod     api 256 CPU / 1024 MB · worker 256 CPU / 512 MB
qnsc-kb prod  api 1024 / 6144       · worker 2048 / 6144
```

rova is a Rally-shaped project tool — CRUD-heavy, modest load, and it earns the money. qnsc-kb is
six times its footprint and earns none. **rova is L because an outage costs revenue; qnsc-kb is M
because an outage costs a delayed answer.** If the presets were resource sizes those letters would
be the other way round, and the platform would protect the wrong product.

So the letters are criticality tiers. A future product that is enormous and unimportant is `XS`
with large `resources`, and nothing about that is a contradiction.

| | XS | S | M | L |
|---|---|---|---|---|
| replica floor | 1 | 1 | 1 dev / 2 prod | 2 dev / 3 prod |
| PodDisruptionBudget | no | no | yes | yes |
| PDB for `realtime` | **yes** | **yes** | yes | yes |
| own Postgres, prod | no — shared | no — shared | shared by default; dedicated on a named reason | yes, + replica option |
| own Postgres, dev | shared | shared | shared | shared |
| cache | none | none | none | dedicated, only with a named reason (§5d) |
| Multi-AZ prod | no | no | no | opt-in |
| node pool | general | general | general | prod on-demand floor |
| examples | ai-dev-kit | solodesk | opshub, kb, LMS | rova |

```yaml
# kb — size M
size: m
services:
  api:      { kind: http, port: 8000, arch: arm64, capacity: ondemand,
              scaling: { type: rps, min: 1, max: 6, target: 200 } }
  worker:   { kind: worker, arch: arm64, capacity: spot,
              scaling: { type: queue, min: 0, max: 4 } }
  beat:     { kind: cron, schedule: "*/5 * * * *" }
  migrator: { kind: job }
data:
  postgres: { mode: { dev: shared, prod: dedicated }, pooling: pgbouncer,
              extensions: [vector, pgcrypto], engine_version: "16" }
  objectStorage: r2
```

**The rule that makes this hold:** presets live in the chart and the module, never copied into
product repositories. The moment a product hand-writes a Deployment because the preset did not
fit, there are seven copies again. If a preset does not fit, the preset gains a field.

### The database row is two rows now, and the reason is restores

Two earlier versions of this table were both wrong, in opposite directions. The first gave every
size-M product its own instance in both environments. The second corrected it to "shared is the
default for XS, S and M" — and justified that with an $89/month saving measured against the first
version, which is a baseline nobody starting fresh would build.

**The honest comparison is against sharing dev and dedicating prod**, which is the arrangement most
people reach for. Using the prices recorded in `rova/infra/live/prod/main.tf` —
`db.t4g.micro` **$13.14/month**, `db.t4g.small` **$26.28**:

| | prod | dev | total |
|---|---|---|---|
| every product dedicated, both environments | 9 instances | 2 instances | **$171** |
| dev shared, every prod dedicated | 6 dedicated, $105 | 1 shared, $26 | **$131** |
| **this design** | see below | 1 shared, $26 | **$91** |

So the saving is **$40/month against the sensible alternative**, not $89 against a strawman. At
that size the decision cannot be made on cost, and should not be.

### It is made on restore granularity

**RDS snapshots and point-in-time restore operate on an instance, not on a database.**

If opshub needs a restore because someone deleted a table, restoring the instance drags LMS,
solodesk back to the same moment. The way out is restoring to a *new* instance and
dumping one database out of it — acceptable on a calm afternoon, miserable at 02:00 during the
incident that created the need.

In dev that costs nothing. In prod it is the operational cost that $40/month does not buy back.
Hence:

```
PROD   rova      dedicated  db.t4g.micro   $13   the only product earning money
       qnsc-kb   dedicated  db.t4g.small   $26   pgvector, a ~16 GiB working set, and
                                                 a workload shape unlike anything else here
       shared    db.t4g.small              $26   opshub · LMS · solodesk · ai-dev-kit
DEV    shared    db.t4g.small              $26   everything, no exceptions
                                           ────
                                            $91
```

**This costs the same $91 as the all-shared version and isolates the two products where isolation
matters** — splitting qnsc-kb out lets the shared prod instance drop from `medium` to `small`, and
that reduction pays for qnsc-kb's own instance. Independent restore for rova and qnsc-kb arrives
free.

The five products on the shared prod instance have no independent restore requirement, no
meaningful traffic, and no workload shape of their own. If any of them develops one, it graduates —
which is the `mode = "shared" → "dedicated"` value change §6 exists to make cheap.

**Dev is shared with no exceptions.** Nothing in a development environment justifies an instance:
not restore, not noisy neighbours, not upgrade timing.

§15 lists RDS at `$125` and calls it "unchanged either way". The *comparison* survives because the
line is identical in both columns — but that figure, like everything else in §15, is priced at
us-east-1 rates for an ap-southeast-1 estate. See §15b.

## 5b. Environment differences

Values are per product **per environment** — `base.yaml` plus `dev.yaml` or `prod.yaml`, rendered
by ArgoCD against one chart. This is strictly better than today, where the dev/prod difference is
spread across two separate OpenTofu stacks and drifts silently; here it is two override files
against one definition.

| | dev | prod |
|---|---|---|
| autoscaling | **off** — fixed 1 replica | KEDA on, per Axis 7 |
| PodDisruptionBudget | **off** | on |
| node capacity | Spot only | `capacity` per service (Axis 6) |
| anti-affinity | none | topology spread across AZs |
| resource requests | low | realistic, VPA-informed (§15b) |
| database | shared, Aurora Serverless v2 at 0 ACU floor | shared provisioned; dedicated for rova |
| log retention | 7 days | 30–90 days |
| trace sampling | 100% | tail-sampled (§9b) |

Turning autoscaling and PDB **off** in dev matters more than it appears. With no disruption budget,
Karpenter drains and deletes a node immediately rather than waiting, so consolidation is
aggressive — and because it bin-packs by *requests*, low dev requests put fifteen services onto
very few nodes.

### No scheduled shutdown, initially

The current ECS estate scales compute to zero and stops databases outside 08:00–24:00 on
weekdays — roughly 48% of the week. **That is deliberately not carried over on day one.**

It costs, and the number should be a decision rather than a surprise:

```
dev databases always-on   5 × ($15 − $7)                  +$40/month
dev nodes always-on       Karpenter holds 2–3 not 1        +$30–50/month
                                                          ───────────
                                                          +$70–90/month
```

The reason is friction, measured. On 2026-09-13 the scheduled stops meant qnsc-kb's and opshub's
develop databases were both down mid-afternoon when they were needed, and one boot test had to be
abandoned because a stopped instance made the result meaningless. A platform that is unavailable
when someone reaches for it gets worked around, and the workarounds are worse than the bill.

Karpenter consolidation, Spot, HPA-off and low requests already deliver most of the saving with
none of that friction.

**Add it later, not never.** When the dev bill justifies it, a KEDA cron scaler takes Deployments
to zero on a schedule and Karpenter removes the empty nodes; the OpenTofu RDS stop/start
schedules already exist and would simply be re-enabled. Design for it now by keeping dev
workloads stateless and startup fast, so the switch is a values change rather than a project.

### Reopened: the decision above conflates compute with databases

The incident that justifies this section is a **database** incident. qnsc-kb's and opshub's develop
databases were stopped, and a stopped RDS instance needs a human and five to ten minutes to come
back — which is why the boot test had to be abandoned rather than delayed. That reasoning is sound
and the conclusion is right for databases.

**It does not transfer to compute, and the two were decided together without being separated.**

```
stopped RDS instance          needs a human. 5-10 minutes. Blocks the person who wanted it.
Deployment scaled to zero     KEDA cron or first-request trigger. 60-90 seconds.
                              Nobody has to know it was down.
```

A 60-second cold start on a development environment is not the friction this section refuses. It is
not even noticeable against the time it takes to open the page.

And the database half is now solved differently anyway: §5d puts the shared dev instance on Aurora
Serverless v2 with a floor of 0 ACU, which wakes on connection in roughly fifteen seconds with
nobody involved. **The 2026-09-13 failure mode is addressed without a schedule at all.**

So the split is:

```
dev DATABASES    no schedule. Aurora Serverless v2, 0 ACU floor (§5d)
dev COMPUTE      KEDA cron scaler to zero outside roughly 08:00-20:00 on weekdays,
                 Karpenter removes the empty nodes
```

Dev then runs about 50 hours a week instead of 168 — roughly **70% off the dev compute line, about
$70/month** at §15's figures, and more before §15d's right-sizing lands.

**This is a reversal of the decision above and it is recorded as one.** The original is kept rather
than deleted because its reasoning is correct and still applies to the half it was actually about.
The mistake was scope: one incident about databases was allowed to settle a question about
compute.

### The cost floor EKS has and Fargate does not

Even fully idle, a dev cluster runs:

```
EKS control plane              $73/month
system pool, one small node   ~$14/month   CoreDNS, Alloy, External Secrets
                              ─────────
idle floor                    ~$87/month
```

On ECS the idle dev compute floor is effectively zero, because Fargate bills per running task.
This is a genuine regression and part of the delta in §15 — named here rather than discovered.

**One mitigation:** run ArgoCD only in the **prod** cluster and let it manage dev remotely. ArgoCD
is multi-cluster native, so the dev system pool then carries only CoreDNS, Alloy and ESO. Saves
roughly $10–15/month and removes one component to upgrade twice.

## 5c. Products with only one environment

Not every product has two environments, and the design handles that without a special case —
worth stating because §5b reads as though everything has both.

```
rova · opshub · qnsc-kb · solodesk · lms     dev + prod    → 2 Applications each
ai-dev-kit                                   prod only     → 1 Application
                                                           = 11 deployments, not 12
```

Nothing bends to accommodate this. An ArgoCD Application exists per (product, environment), so a
prod-only product simply has no dev Application; there is only `prod.yaml` and no `dev.yaml`; and
`module "product"` is called once rather than twice. Absence is the mechanism.

### But a prod-only shared service becomes a cross-environment dependency

This section used to analyse a real problem. A self-hosted Flagsmith existing only in production
meant rova's *develop* environment read flags from a *production* service — so one outage took out
flag evaluation in every environment at once, a careless upgrade hit production with no earlier
environment to catch it, and development traffic reached a production system, which matters for
audit scope.

**That subject is gone.** §4c replaces self-hosted feature flags with a SaaS subscription, so there
is no in-cluster flag service to have environments at all.

The analysis is kept because the *shape* of it recurs — **any prod-only shared service creates this
dependency**, and the embedding server anticipated in §4c would create it again. Two rules fall out
for whatever arrives next:

* **Treat a single environment as production, not as a compromise.** It lives in the prod cluster,
  at prod replica counts, with a PodDisruptionBudget, and is upgraded with the same care as rova.
  "It only has one environment" must not become "it is the environment where we experiment."
* **Verify that consumers degrade rather than break.** A well-behaved client caches locally and
  falls back to a default. That assumption is the difference between a degraded feature and an
  outage, and it is worth testing rather than hoping for.

### Where a prod-only product gets rehearsed

There is no dev instance to try a version bump in, which is a genuine gap. Two answers, in order
of preference:

1. **Preview environments (§11).** A PR bumping `flagsmith/flagsmith` to a new tag spins up a
   full instance in the dev cluster against the preview Postgres. That is a better rehearsal than
   a permanent dev instance, because it is built from the same manifest that will reach prod.
2. **Add a dev Application when it earns one.** For an XS product this costs a values file and a
   little Spot capacity. The design makes it a one-line change precisely so this is not a
   migration later.

The rule: **prod-only is a starting position, never a constraint.** Any product gains a second
environment by adding `dev.yaml` and one Application.

## 5d. The shared data tier, defined

`mode = "shared"` appeared in the first draft as one clause in §6 and was never defined. §5 settles
where the line falls; this section says what "shared" actually is, and what it costs to be on the
shared side of it.

```
PROD   rova · qnsc-kb    dedicated instances
       everything else   one shared instance
DEV    everything        one shared instance
```

### One instance, database and role per product

```sql
CREATE DATABASE opshub;
CREATE ROLE opshub LOGIN;
-- no cross-grants: a role reaches its own database and nothing else
```

Be honest about which isolation this buys, because a reader should be able to check the claim
rather than take it:

| isolation | shared instance gives it? | consequence |
|---|---|---|
| data — database, role, no cross-grant | **yes** | complete, and it is the one most people mean |
| **restore — point-in-time, per database** | **no** | **the reason prod is not fully shared (§5)** |
| performance — noisy neighbour | no | bounded below, and made visible |
| availability — one instance, one fate | no | true; acceptable for internal tools, not for revenue |
| major-version upgrade timing | no | a *benefit* at this size for the shared set: one upgrade, not five |

The restore row is the one that decides the design. RDS snapshots and PITR operate on an instance,
so restoring one product's data restores every product on that instance — which is why rova and
qnsc-kb are dedicated in production and why nothing is dedicated in development.

**The graduation path is a value, not a project.** A product on the shared instance that develops a
restore requirement, a distinct workload shape, or real traffic changes `mode = "shared"` to
`mode = "dedicated"` in §6. That is the "adapt as it grows" property expressed where it has to be.

Noisy neighbours on the shared instance are bounded per role, at no cost:

```sql
ALTER ROLE opshub SET statement_timeout = '30s';
ALTER ROLE opshub SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE opshub CONNECTION LIMIT 40;
```

**Two roles per product, not one — because the timeout above would kill migrations.** §4 sets the
migration job's timeout to 600s deliberately, on the grounds that the default *"will kill a slow
migration part-way, which is the worst possible moment."* A migrator connecting as the application
role would instead die at 30 seconds, and the two sections would cancel each other out:

```sql
CREATE ROLE opshub_migrator LOGIN;
ALTER ROLE opshub_migrator SET statement_timeout = '600s';   -- matches §4's job timeout
-- DDL rights live here and nowhere else
```

This is better than a shared role regardless of the timeout: the runtime role has no business
holding `CREATE`, `ALTER` or `DROP`, and separating them means a compromised application cannot
reshape its own schema.

with `pg_stat_statements` enabled and a Grafana panel of top queries by total time, grouped by
role. That turns "the database is slow" from a mystery into a name.

### Connection pooling is mandatory, not a tuning option

This is the failure that works perfectly in dev and arrives the first time production scales, and
consolidating databases makes it arrive sooner:

```
HPA 2 → 6 api pods × pool of 10        60
workers × pool of 10                   30
migration job                           5
× products sharing the instance      300+ connections
```

`db.t4g.small` allows roughly 200 and `medium` roughly 340, and Postgres degrades well before
either limit because every connection is a backend process.

**Correction — a Deployment, not a sidecar.** An earlier version of this section specified "a
PgBouncer sidecar, in transaction mode". Building it showed the sidecar does not solve the problem
the arithmetic above describes: a sidecar pools **per pod**, so six api pods with a sidecar each
still open six pools to Postgres. That is halved, perhaps, but still **linear in replicas** — and
not growing with replicas was the entire point.

One PgBouncer Deployment per product holds a single pool regardless of how far the application
scales, so Postgres sees a constant number. It costs one extra hop (~0.3 ms in-namespace) and a
component that must not fall over, hence two replicas and a PodDisruptionBudget in production.

The sidecar form is not useless and may be added on top later: it terminates the application's
connection *churn* locally, which matters with the RDS IAM authentication §8 chose, where every new
connection mints a token. But it is an optimisation on top of the pooler, not the pooler. Dedicating rova and qnsc-kb reduces the
pressure on the shared instance but does not remove it — and it does nothing at all for qnsc-kb's
own instance, where a single product's autoscaling can exhaust connections by itself. **PgBouncer in transaction mode, rendered by the chart whenever
`data.postgres` is set.** RDS Proxy is the managed equivalent at roughly $15/month per instance;
the sidecar is free and transaction pooling is the mode that actually helps. Either is fine — what
is not fine is leaving it to each product to discover.

```yaml
data:
  postgres:
    mode: shared
    pooling: pgbouncer     # chart default; `rdsproxy` or `none` are the overrides
```

### Dev databases: scale to zero instead of stopping on a schedule

§5b declines to carry over the scheduled stop/start, and the reason given is a measured one —
on 2026-09-13 the qnsc-kb and opshub develop databases were both stopped mid-afternoon when they
were wanted, and a boot test had to be abandoned. That reasoning is right and the conclusion does
not have to be "always on".

**Aurora Serverless v2 with a floor of 0 ACU** for the shared dev instance costs active hours
only and wakes on connection in roughly fifteen seconds. That is a different thing from a stopped
instance: nobody has to know it was asleep, and no one has to start it. The friction §5b
correctly refuses does not come back with it.

Prod stays on provisioned RDS, where steady-state ACU pricing is worse than an instance.

### ElastiCache: consolidate to one, and do not try to remove it

A first version of this section said to remove Redis outright, on the assumption that the estate
used it for a job queue that SQS could take over. **That was wrong, and the measurement is worth
recording because the wrong version was more attractive.** What Redis actually holds:

```
qnsc-kb        Celery broker — `broker=settings.REDIS_URL` in src/workers/celery_app.py
               rate limiting — src/core/rate_limit.py
rova · opshub  app-platform/packages/platform-cache, "shared Valkey/Redis cache
               primitive", plus ioredis in platform-http
               NO BullMQ. Their only SQS use is SES bounce handling.
```

So three uses, and each fails a different way if moved:

| use | can it move? | why not |
|---|---|---|
| Celery broker (kb) | **no** | see below |
| shared cache (rova, opshub) | no | an in-process LRU is not a coherent cache across replicas |
| rate limiting | **partly** | Cloudflare limits on IP, path and header, which covers abuse. It cannot express a per-tenant or per-API-key quota the application knows about. Edge-shaped rules move; tenant-shaped rules stay. |

**Celery must not move to SQS.** Celery's SQS transport drops the things that matter during an
incident:

```
celery inspect / celery control    unsupported on the SQS transport — no worker
                                   introspection, exactly when it is wanted
priority queues                    unsupported
ETA / countdown                    SQS caps delay at 15 minutes; Celery emulates
                                   longer delays by re-queueing, which is worse
transport maturity                 less battle-tested than AMQP or Redis
```

Worker introspection during an outage is worth more than $12/month to a team of three.

**The decision is consolidation, not removal:**

```
ONE cache.t4g.micro per environment, database index per product
  db 0   qnsc-kb   Celery broker
  db 1   qnsc-kb   rate limiting
  db 2   rova      platform-cache
  db 3   opshub    platform-cache
```

Against `$24.23` measured at three products and $32 projected at seven, one instance per
environment is roughly **$24/month — a saving of about $8, not $25.** Small. The reason to do it
anyway is that it stops the line growing with product count, which is the §"reframe" property
every other item in §15b is chosen for.

Managed rather than self-hosted, deliberately: a Celery broker that loses its queue on restart
loses work, so this wants persistence and failover, and §13 forbids PVCs outside the lab.

## 6. The `product-profile` OpenTofu module

Cloud resources need the same capability flags, or the flexibility stops at the cluster edge.

```hcl
module "product" {
  source  = "…/modules/product-profile?ref=product-profile-v1.0.0"
  product = "kb"
  env     = "prod"
  size    = "m"

  postgres = { mode = "dedicated", pooling = "pgbouncer",
               extensions = ["vector"], engine_version = "16" }
  cache    = { mode = "none" }
  storage  = { r2_buckets = ["sources", "attachments"] }
  queue    = { sqs = true }
}
```

`mode = "shared"` provisions a database and role on the shared instance (§5d); `mode = "dedicated"`
provisions an RDS instance of its own. The interface is identical either way, so a product
graduates from shared to dedicated by changing a value — which is the "adapt as it grows" property,
expressed where it has to be expressed. rova is the only product that starts dedicated.

`cache = { mode = "none" }` is now the default for every product, and §5d is the argument for why.
`queue = { sqs = true }` is what replaces it where the need was actually a job queue.

qnsc-kb is shown as `dedicated` because it is one of the two products §5 dedicates in production —
pgvector, a ~16 GiB working set, and a workload shape unlike anything else in the estate. The same
module call for `env = "dev"` sets `mode = "shared"`, because nothing in a development environment
earns an instance.

## 6b. Messaging

Nothing in the first draft said what carries an event between two services, and §16 settled only
the negative half ("no Kafka"). This section settles the positive half.

### The question is not throughput

`rova/apps/worker/src/audit/audit-projection.relay.ts` records what actually went wrong with
messaging in this estate, and it is not volume:

> "This relay used to publish to an SNS topic that fanned out to four SQS queues… That pipeline
> was **broken in every deployed environment, in three independent ways, and no metric or alarm
> showed it**:
>
> 1. Only ONE subscription existed… the audit queue was never subscribed, so the consumer polled
>    an empty queue forever.
> 2. That subscription filtered on `eventType ∈ {notification.created, notification.updated}` —
>    values this codebase never emits. Measured on develop: **12 published, 12 FilteredOut, 0
>    delivered, 0 failed.**
> 3. The messaging module set no `raw_message_delivery`, so SQS would have delivered the SNS
>    envelope while the consumer parsed it as the bare event…
>
> "Local dev worked, which is what kept it hidden: `scripts/localstack/01-bootstrap.sh` subscribed
> all four queues, unfiltered, with raw delivery on. It was more generous than the Terraform, so
> dev could not reproduce prod."

All three are topology drift, and none would have been prevented by a different broker. Kafka,
RabbitMQ and NATS each have their own version of "the deployed topology is not the tested
topology", and two of them add a cluster to operate underneath it. **The selection criterion is
therefore verifiability, not throughput.**

### Four needs, which are not one need

| need | today | answer |
|---|---|---|
| in-product background work | Celery (kb), `@nestjs/schedule` (rova, opshub) | keep. `worker` kind, KEDA queue trigger (Axis 7) |
| outbox → projection in the same database | `AbstractOutboxRelay`, DB to DB | **keep — it is correct.** A broker adds nothing here |
| work queue between services | `modules/messaging`, currently SES bounce only | **SQS.** Already built |
| cross-product domain events | does not exist yet | **EventBridge**, when the second consumer appears |
| replayable event log | does not exist | not needed; EventBridge archive and replay covers it if it ever is |

The transactional outbox is already the messaging primitive here — `messaging.outbox_events`
exists in rova, opshub and qnsc-kb, and `AbstractOutboxRelay` is shared in `libs/platform`. It
provides durability and at-least-once delivery with idempotency by `sourceEventId`. A broker is
not a replacement for it; a broker is the *transport* for the case where the consumer is not in
the same database.

The relay comment already fixes the trigger, and this document adopts it unchanged:

> "If a genuine second consumer appears (a cross-product subscriber, a search indexer),
> reintroduce the topic THEN — with an end-to-end test that runs against the deployed topology
> rather than a hand-written local approximation."

### EventBridge rather than SNS, and the reason is failure #2

```
SNS            filter policies match MESSAGE ATTRIBUTES only. A filter matching values
               nothing emits is indistinguishable from a working filter: FilteredOut is
               the success path for a filter, not an error.
EventBridge    content-based routing over the EVENT BODY, a schema registry, and
               archive with replay.
```

A schema registry turns "filters on an eventType the codebase never emits" into a build-time
mismatch rather than a CloudWatch metric nobody reads. At this volume the price difference is
noise — EventBridge $1.00 per million events, SNS $0.50 per million, against twelve published.

SQS stays for work queues. `tf-modules/modules/messaging` already provisions queue, DLQ and
policy, so the module exists and does not need replacing.

### What was rejected, with the floor cost of each

| | floor | why not |
|---|---|---|
| **Kafka — MSK Serverless** | **$0.75/hour ≈ $547/month** | nothing in this portfolio streams. §16 excluded it and nothing has changed |
| Kafka — MSK provisioned, 2 brokers | ~$150/month | same, plus brokers |
| Kafka — Strimzi, self-hosted | ~$40/month of node | three stateful pods and PVCs, which §13 forbids outside the lab |
| RabbitMQ — Amazon MQ | $19/month single, ~$56/month clustered | single instance is a single point of failure; clustered costs more than the problem. The real argument for RabbitMQ is Celery's AMQP transport, which is an argument for keeping qnsc-kb's broker (§5d), not for platform RabbitMQ |
| **NATS JetStream** | ~$15/month of node | see below |
| **SQS + EventBridge** | **~$0** | first million SQS requests per month free. IAM through IRSA, so no credential |

**NATS JetStream is the honest runner-up and it loses on consistency, not on merit.** It is the
best self-hosted option for a Kubernetes-native team: a single Go binary at roughly 30–50 MB
resident, no JVM and no ZooKeeper, with core pub/sub, request-reply, persistent streams and a KV
store in one process — the KV could even absorb part of what §5d keeps Redis for.

Against it: JetStream file storage needs PVCs (§13), it becomes a fourth version-pinning component
in §2b, and it introduces a broker credential into an estate that recorded **two credential
failures in one week that nothing detected** (§8). This document refuses to self-host in four other
places — LGTM (§9i), Crossplane (§7), service mesh (§4b), Kafka (§16) — for the same reason each
time. NATS being genuinely good does not change the arithmetic for two or three engineers.

**Revisit when** cross-product request-reply at low latency becomes a requirement, or an in-cluster
KV or object store is wanted. Neither is true; §4b chose HTTP over cluster DNS for service-to-service.

### Three controls, one per recorded failure

Choosing EventBridge changes nothing if the same class of bug recurs, so each failure gets a
control rather than a fix:

**1. `raw_message_delivery = true` is the module default.** Failure #3 was the module setting
nothing at all. A default that is wrong in a shared module is wrong in seven places at once.

**2. No filter policy without a test that proves what it passes.** Failure #2 was a filter matching
values nothing emits, and there is no error state for that — a filter that drops everything looks
exactly like a filter that is working. Default to no filter; adding one is a deliberate act that
arrives with its test.

**3. Three metrics, rendered by the chart alongside the queue (§9e).** All three failures were
visible in CloudWatch the entire time:

```
published vs delivered vs FilteredOut    a sustained nonzero gap is a finding
ApproximateAgeOfOldestMessage            catches both "nobody consumes" and
                                         "consumer polls an empty queue forever"
DLQ depth > 0                            always an alert, never only a dashboard
```

**And the structural fix is already in this design.** All three bugs survived because
`scripts/localstack/01-bootstrap.sh` was more generous than the Terraform, so dev could not
reproduce prod. §11's preview environments remove that possibility by construction: a PR gets a
real namespace with real AWS resources, built from the manifest that reaches production. Local
approximation drift cannot exist when the tested topology *is* the deployed topology.

## 7. The OpenTofu ↔ Kubernetes boundary

One rule: **if it outlives a deploy, OpenTofu owns it.**

```
OpenTofu     VPC · subnets · fck-nat · EKS · Karpenter IAM
             RDS · ElastiCache · Cloudflare R2 · IRSA roles
             Secrets Manager containers · DNS · budgets · alarms

Kubernetes   Deployments · Services · HPAs · Jobs · CronJobs
             ArgoCD Applications · Alloy · External Secrets Operator
```

**No Crossplane.** Managing AWS from inside the cluster removes the `tofu plan` review gate,
which is currently the only place a human sees a destroy before it happens, and has weaker drift
semantics. Keeping this boundary sharp is what keeps the platform comprehensible.

## 7b. Five paths, stated once

Each of these is decided somewhere in this document and none of them is written down whole.
Someone joining should be able to read five diagrams rather than seventeen sections.

```
REQUEST    internet → Cloudflare (WAF · rate limit · Access · cache · TLS)
           → tunnel → cloudflared ×3 → Gateway → HTTPRoute → Service
           → pod → PgBouncer → RDS
                                                            §3 · §5d · §9j

DEPLOY     PR → CI: test, build multi-arch, sign, push ECR with an immutable tag
           → merge bumps the dev tag in `gitops` → ArgoCD syncs dev
           → promotion PR changes the prod tag → approval → ArgoCD syncs prod
           rollback = revert that commit
                                                            §11

TELEMETRY  app (OTLP) ────┐
           node agent ────┼→ Alloy gateway ×2 → Grafana Cloud
           Cloudflare ────┘   (tail sample · allowlist · one credential)
           Logpush → R2
                                                            §9b · §9g

SECRET     human → Secrets Manager → ESO (per-namespace SA + IRSA)
           → Kubernetes Secret → pod env
           never in git · never in OpenTofu state
                                                            §8

DATA       pod → IRSA → RDS IAM token (15 min) → PgBouncer → Postgres
           no long-lived database password exists anywhere
                                                            §5d · §8
```

The `DATA` path is the one that changed: a database password was a credential in §8's rotation
inventory, and now there is nothing to rotate.

## 7c. Naming, so nothing has to be passed between repositories

§7 draws the boundary between OpenTofu and Kubernetes. Things still have to cross it: `infra`
creates an ECR repository, an IRSA role and a Secrets Manager entry, and `gitops` has to name all
three. Either those names are communicated — outputs, a generated file, copy-paste — or they are
**derived on both sides from the same three variables and never communicated at all.**

Derivation is the cheaper option by a wide margin, because a name that is computed cannot drift.

### The rule

**A name encodes exactly the dimensions the thing varies on. No more, no less.**

Most naming schemes fail by adding a dimension that does not apply, and the important instance here
is the registry:

```
ECR repository    rova-api      ← carries NO environment, and that is load-bearing
```

§11's promotion model is "the same image gets a second tag". If repositories were `rova-api-dev`
and `rova-api-prod`, promotion would mean **copying bytes between repositories** — a different
digest, and the attestation §11 verifies would no longer cover what runs in production. The current
naming already prevents this. It should not be "fixed".

### The table

```
                        dimensions                  example
ECR repository          product + service           rova-api
k8s namespace           product                     rova        (the cluster IS the env)
Deployment / Service    service                     api         (the namespace IS the product)
ServiceAccount          service                     api
cluster DNS             derived                     api.rova.svc.cluster.local

IRSA role               qnsc + env + product + svc  qnsc-prod-rova-api
Secrets Manager         qnsc/env/product/name       qnsc/prod/rova/database-url
RDS, dedicated          product + env               rova-prod
RDS, shared             qnsc-shared + env           qnsc-shared-prod
Postgres database       product                     rova
Postgres roles          product · product_migrator  rova · rova_migrator
SQS queue               qnsc + env + product + use  qnsc-prod-rova-email-bounce  (+ -dlq)
R2 bucket               qnsc + env + product + use  qnsc-prod-kb-sources

DNS, prod               product                     rova.qnsc.vn
DNS, dev                product + dev               rova.dev.qnsc.vn
ArgoCD Application      product + env               rova-prod
OTel service.name       product + service           rova-api    ← matches ECR deliberately
cost allocation tags    product · env · size        §12
```

Two derivations are worth pointing at. **The namespace carries no environment**, because §2 puts
dev and prod in separate clusters — `rova-dev` inside the dev cluster says it twice. And **the
Deployment is `api`, not `rova-api`**, because the namespace already said rova; that is what makes
§4b's `orders.rova.svc.cluster.local` read as an address rather than a mangled string.

`service.name` matching the ECR repository is also deliberate: a trace in Tempo and an image in ECR
name the same thing, so "which build produced this span" needs no lookup table.

### The Secrets Manager path is not cosmetic

§8 wants a `SecretStore` per namespace whose IRSA role can read that product's secrets and nothing
else. A slash-delimited path makes the policy one statement:

```
arn:aws:secretsmanager:ap-southeast-1:608983206583:secret:qnsc/prod/rova/*
```

Flat names would mean enumerating every secret in the policy and editing it on every addition —
which is the kind of chore that gets skipped, leaving the wildcard nobody meant to grant.

### Four decisions the existing estate forces

**1. `dev` and `prod`, not `develop` and `production`.** The live OpenTofu uses `env = "develop"`
and `"production"`; this document uses `dev` and `prod` throughout and §2 names the clusters that.

Canonical is **`dev` / `prod`**, with one grandfathered exception:

```
the mismatch is DEV ONLY   `env_slug = "develop"` in dev, `env_slug = "prod"` in prod
                           (rova/infra/live/prod/main.tf:90). Production already matches
                           the convention — rova/infra/live/prod/main.tf:88 says so
                           explicitly: "Resources are named `rova-prod`, not
                           `rova-production`"
RDS instance identifiers   KEEP rova-develop and the rest. Renaming an instance changes
                           its ENDPOINT HOSTNAME, so it is a coordinated connection-string
                           change rather than a rename
everything else            normalized during the migration. The IRSA roles are new regardless
                           (EKS OIDC trust, not ECS task roles), and every ECS-derived name
                           disappears with §17b's shrink
```

Half of this was already done, deliberately, before this document existed. The grandfathering is
therefore one word in one environment, not a vocabulary.

Recording the exception is what keeps it a decision rather than drift — the same device §1 uses for
qnsc-kb's split repositories.

**2. Postgres identifiers use underscores.** A role named `qnsc-kb` requires double-quoting in every
statement for the life of the database. Hyphens everywhere else; underscores inside Postgres:
`qnsc_kb`, `rova_migrator`.

**3. The qnsc-kb slug becomes `kb`.** Three names exist for one product today — ECR `qnsc-kb-api`,
repositories `qnsc-kb-backend`, and this document's own examples `kb`. With the `qnsc-` prefix on
AWS resources the long form double-prefixes: `qnsc-prod-qnsc-kb-sources`.

The rename is close to free **because §4c already requires rebuilding qnsc-kb's images** — splitting
clamav out moves the api and worker to arm64, so new images are pushed regardless. Create `kb-api`,
`kb-worker` and `kb-migrator`; let the old repositories expire on their retention (§13). The
repository names `qnsc-kb-backend` and `qnsc-kb-frontend` stay — they are GitHub names, not
resource names, and renaming them buys nothing.

**4. Preview namespaces need their own shape**, because §11's ApplicationSet creates one per pull
request:

```
namespace   preview-<product>-<pr>          preview-rova-412
hostname    <product>-<pr>.preview.qnsc.vn  rova-412.preview.qnsc.vn
database    preview_<product>_<pr>          on the shared preview instance
```

The `preview-` prefix is what makes §12c's quarterly orphan check tractable: anything carrying it
with no open pull request is garbage, and that is decidable by a script.

### Repositories

§7c is about resources, but the same discipline applies one level up and the estate is about to
gain its only new repository:

```
products    named for the product    rova · opshub · qnsc-kb-backend · qnsc-kb-frontend
                                     solodesk · lms · ai-dev-kit
platform    named for the function    gitops · infra · tf-modules · ci · docs
```

`gitops` follows that rule. `delivery`, which an earlier draft used, did not — it is a function
name that reads as a business noun, and in a semiconductor company "delivery" means shipping
before it means deployment.

### The one fact declared twice

`size` appears in both repositories, and nothing prevents them disagreeing:

```
gitops/values/rova/prod.yaml        size: l
infra/live/rova/production/main.tf    size = "l"
```

**Do not build a generator for this.** A CI check is ten lines and catches the only drift that
matters:

```
for each gitops/values/<product>/<env>.yaml
    read `size`
    read the `size` argument from the matching infra/live/<product>/<env>
    fail the build if they differ
```

Making one side authoritative would mean generating Terraform from YAML or the reverse, and the
machinery would cost more than the problem. Everything else crossing the boundary is derived, so
this is the only pair that needs checking.

## 8. Secrets

```
Secrets Manager → External Secrets Operator → Kubernetes Secret → pod env
```

OpenTofu creates the containers; values are written out of band and never enter state or git.

**A `SecretStore` per namespace, each with its own service account and IRSA role** — not one
`ClusterSecretStore`. Cluster-wide is less setup and means a single compromised namespace can read
every product's secrets. Per-namespace keeps the blast radius equal to the namespace, which is the
same principle as the NetworkPolicies in §10.

This fixes a measured failure. On 2026-09-06 the Grafana OTLP credential was rotated and the
`observability-token` field was updated in **four separate secrets**, one per product per
environment. The value was wrong — built from the org id rather than the stack id — and rova and
opshub shipped no metrics or traces for **seven days**. With Alloy there is **one** credential in
one place.

### The database credential that should not exist

Pod-to-RDS authentication is not settled anywhere in this document, and the two options are not
equivalent:

```
password in Secrets Manager → ESO → pod env     one more credential in the §8 inventory,
                                                one more thing to rotate, one more thing
                                                that can be rotated wrongly
RDS IAM authentication via IRSA                 a 15-minute token minted per connection.
                                                Nothing to store, nothing to rotate,
                                                nothing to get wrong on 2026-09-06
```

**Use IAM authentication.** It removes an entire credential class from the rotation inventory
below rather than managing it better, and IRSA is already required for ESO and for R2 access. The
constraint to check before committing: IAM auth has a connection-establishment cost and a
per-second connection cap, which is a reason PgBouncer (§5d) is required rather than merely
advisable — a pooler makes connection establishment rare.

### Rotation

Two credential failures happened in one week, and neither was noticed by anything:

```
2026-09-06   Grafana OTLP credential rotated, replacement wrong → 7 days of no telemetry
2026-09-11   Grafana alerting service-account token stopped being accepted → 2 days,
             found only because an unrelated `tofu plan` failed on it
```

Both were hand-written values with no expiry tracking and nothing testing them. So:

```
inventory     every credential ESO syncs, with owner, source system, and rotation interval
verification  alerting_health probes each one — a credential that cannot authenticate is a
              finding the next morning, not a discovery weeks later
rotation      annually at minimum; immediately on suspicion; recorded when done
```

The verification matters more than the schedule. A rotation policy nobody follows is a document;
a daily probe that fails loudly is a control.

## 9. Observability

### 9a. The contract: OTLP, and semantic conventions that are actually shared

**Applications emit OTLP and nothing else. No vendor SDK ever enters application code.** That one
rule is what keeps the storage decision in §9i reversible, and it costs nothing to hold from the
start.

The part that is easy to skip and expensive to retrofit is naming. A shared module in
`app-platform` sets the resource attributes from the environment, and pins one version of the
OpenTelemetry semantic conventions:

```
service.name · service.version · service.namespace · deployment.environment
```

Without it, seven products name the same concept seven ways and no dashboard, alert or query is
portable between them. That is the duplication this entire document exists to remove, reappearing
one layer up — and it is cheaper to prevent than the compute duplication, because nothing has been
built yet.

### 9b. Collection: Alloy in two tiers, and why one tier is not enough

```
apps (OTLP) ──────┐
                  ├──→ Alloy "gateway" Deployment ×2 ──→ Grafana Cloud
Alloy DaemonSet ──┘
```

| tier | workload | carries |
|---|---|---|
| agent | DaemonSet | node logs, cAdvisor, node-exporter, kube-state-metrics, eBPF profiles |
| gateway | Deployment ×2 | OTLP receiver, **tail sampling**, metric allowlist, batching, the one egress credential |

This replaces four sidecar modules per service — `otel_agent_api`, `otel_agent_worker`,
`firelens_agent_api`, `firelens_agent_worker` — because ECS has no node-level agent and every task
needs its own collectors.

**The gateway Deployment is required, not an optimisation.** Tail-based sampling needs every span
of a trace to reach the same collector, and a DaemonSet cannot offer that: the spans of one request
land on whichever nodes its pods happen to occupy. The existing ECS module README already recorded
this as an open gap — *"tail sampling is deliberately not attempted there (needs a trace-id-aware
gateway that does not exist yet — a real future gap, not this one)"*. Kubernetes is where that gap
closes, and it closes for the cost of two small pods.

It is also, incidentally, the §8 argument applied to telemetry: one credential in one Deployment
rather than one per node.

```
keep 100%   any span with an error status
keep 100%   latency above the p99 threshold
keep 100%   any trace touching an authentication or payment path
keep 2–5%   everything else
```

Head sampling at 5% — the alternative — discards 95% of the errors along with 95% of the successes,
which is exactly backwards.

### 9c. Six signals, not three

```
metrics     OTLP / Prometheus          → Mimir
logs        structured JSON            → Loki
traces      OTLP                       → Tempo
profiles    continuous, eBPF           → Pyroscope
RUM         browser sessions           → Faro
synthetics  outside-in probes          → Synthetic Monitoring
```

The first three are the ones usually asked for. The other three are where the gaps in this estate
actually are:

**Profiles** answer the question metrics raise and cannot close — a CPU graph says *how much*, a
profile says *which function*. eBPF-based collection needs no code change and no SDK, and Alloy
already runs on every node for logs.

**RUM** matters here specifically because the front doors are outside the cluster: the qnsc-kb
frontend is on Cloudflare Pages and rova's web app is served at the edge. Faro links a browser
session to the backend trace it produced, which is the only way "the app is slow" becomes a
question with an answer.

**Synthetics** are the outside-in check that does not depend on the estate working. §8 records two
credential failures in one week, one found only because an unrelated `tofu plan` failed on it; and
every alarm topic in this account had zero subscribers for weeks. Every internal signal shared the
same blind spot, which is what an external probe is for.

**eBPF is the floor, SDK instrumentation is the upgrade** — with one exception for gRPC and Go,
where the order reverses (§4d). Grafana Beyla, or Alloy's eBPF
components, produce RED metrics and basic traces from the kernel with no application change. That
means clamd — a third-party image nobody here wrote — gets golden signals, and so does any
service whose instrumentation work has not happened yet. It is the cheapest way to make "monitor
every product" true on day one rather than at the end of a backlog.

### 9d. The cardinality budget

Observability bills scale on cardinality, not on traffic — which is why a small estate can produce
a large invoice, and why every rule below is about labels rather than volume.

**The estate is on Grafana Cloud's free tier today, and the goal of this section is to stay there.**
§15 budgets $75 as a provision against six signals at fifteen services, not as a measurement. Every
rule below is written to defend the free tier rather than to trim a bill that already exists — see
§15e for the check that settles which it is.

```
metrics   Adaptive Metrics on from day one. It aggregates away series that no
          dashboard and no alert reads — the automated form of the hand-written
          allowlist, and it is included in the plan.
          Drop the `pod` label wherever a dashboard reads `app`: HPA and Spot churn
          regenerate pod names constantly, so every rollout mints a fresh series set.
logs      Loki indexes LABELS ONLY. Labels are {cluster, namespace, app, level} and
          nothing else. trace_id, user_id and request paths live in the body and are
          queried at read time. High-cardinality Loki labels are the single most common
          way a small team turns a $50 bill into a four-figure one.
          Drop /health access logs at the gateway — typically ~40% of volume, none of
          the value. Drop debug level in prod.
traces    Tail sampling as in §9b. 7–14 day retention.
profiles  eBPF only, no SDK profilers, 7 day retention.
```

With that discipline six signals across fifteen services land at roughly **$50–90/month**, and
plausibly inside the free tier. Without it, the same six signals cost several hundred. The
difference is entirely labels, so it is decided once, in the gateway configuration, rather than
per product.

Check the series count after the first cluster is running, not after the first invoice.

### 9e. SLOs are chart values, and alerts burn budget rather than cross thresholds

Axis 8 renders this. It is written here because the reasoning belongs with observability:

```yaml
slo:
  availability: 99.5
  latency: { p99: 500ms }
```

The chart emits the recording rules and the multi-window, multi-burn-rate alerts. Two properties
follow, and both are answers to recorded failures:

* **An alert cannot be forgotten**, because it is rendered beside the Deployment rather than built
  by hand afterwards. "Alarms are configured" was true of this account while every alarm topic had
  zero subscribers.
* **Alerting is on error budget, not on CPU.** A team of two or three cannot absorb threshold
  noise, and threshold alerts on an IO-bound service fire for the wrong reasons anyway. Page on
  "this will exhaust the budget", not on "CPU exceeded 80%".

### 9f. Dashboards per service kind, not per product

The chart already knows what kind each service is. So does the dashboard set:

```
http · worker · job · cron        four dashboards, parameterised by namespace
```

Four dashboards cover fifteen services, and a new product arrives with working dashboards rather
than with a dashboard task. This is the §4b property applied to observability — and the failure it
prevents is the same one: seven hand-built copies that drift.

Dashboards live in `gitops` as code, and are reconciled like everything else.

### 9g. The Cloudflare blind spot

§3 makes Cloudflare the real front door — WAF, rate limiting, Access, TLS, and the tunnel itself.
None of that is visible from inside the cluster, so today "the site is slow" has no data anywhere
upstream of the Gateway, which is where most of the interesting failures would be.

```
Cloudflare Logpush → R2 → Alloy → Grafana Cloud
```

WAF blocks, rate-limit events, Access denials, edge latency and tunnel connector health belong in
the same place as everything else. This is the layer the architecture leans on hardest and the one
it currently cannot see.

### 9h. Meta-monitoring: who watches the watcher

On 2026-09-06 a rotated Grafana credential was replaced with a wrong value and rova and opshub
shipped no metrics or traces for seven days. Nothing noticed, because the thing that would have
noticed was the thing that was broken.

```
dead-man's switch    an always-firing alert routed to a heartbeat endpoint;
                     silence is the failure signal
absence alerts       absent_over_time(up{namespace="rova"}[10m]) per namespace
credential probes    §8's alerting_health checks each credential can authenticate
```

Cheapest control in this document, and it is aimed directly at the incident that motivated §8.

### 9i. Why Grafana Cloud, and the number that changes it

| option | verdict |
|---|---|
| **Grafana Cloud** | **chosen.** The only one covering all six signals on one bill, OTLP-native, and already in use. |
| Datadog | best interface available; per-host plus per-custom-metric pricing puts seven products across two clusters past $1,000/month. |
| SigNoz / HyperDX (ClickHouse) | genuine contender — one store for all signals, cheap at volume. Self-hosting adds a stateful system; the managed tiers are real. Revisit at the trigger below. |
| AWS AMP + AMG + X-Ray | managed Prometheus and Grafana, but logs and traces are separate products with worse correlation. This estate left CloudWatch deliberately. |
| Honeycomb | the best query model in the category, trace-centric, priced per event. Overkill at fifteen services. |

**Do not self-host LGTM.** Total CloudWatch log storage today is 0.19 GB. Self-hosting means
running Mimir or Thanos, Loki, Tempo and now Pyroscope — four or five stateful distributed systems,
plausibly more operational work than the application platform itself.

`ARCHITECTURE_FUTURE_SCALE.md` gates this on "managed bill grows / need residency / high volume",
which is the right shape but not a number. **The trigger is a Grafana Cloud bill above $500/month,
or a data-residency requirement.** Below that, the managed bill is cheaper than the engineer-hours,
and §9a's OTLP-only rule means the move is a change of endpoint rather than a re-instrumentation.

## 9j. Performance

Nothing in the first draft addressed latency or saturation, which left three things implicit that
each fail in production and not in dev.

### Probe discipline: the cascading-failure trap

```
liveness     the process is alive. No dependency checks. Ever.
readiness    this replica can serve — may check dependencies
startup      slow boots use startupProbe, never a long liveness delay
```

If liveness checks the database and the database slows down, Kubernetes kills every replica of
every service at once, and a slowdown becomes an outage. qnsc-kb boots slowly by nature — the
e5-large-instruct ONNX session is roughly 1.5 GB resident — so it needs a `startupProbe` rather
than a generous liveness threshold.

The chart should make the mistake unavailable: expose `readinessPath` as a value, and render
liveness against a trivial endpoint that the product cannot point at a dependency.

### Cross-AZ traffic is invisible and grows with the square of service count

Pod-to-pod across availability zones costs $0.01/GB in each direction, appears on no per-service
line item, and gets worse as services multiply — fifteen services, plus Alloy shipping telemetry,
plus cloudflared to Gateway to pod.

```yaml
spec:
  trafficDistribution: PreferClose     # Kubernetes 1.31+
```

One field, set as a chart default on every Service. Cheaper **and** lower latency, which is rare
enough to be worth doing without further analysis.

### The tunnel hop, stated so the §3 decision has a trigger

`Cloudflare edge → tunnel → cloudflared → Gateway → pod` adds roughly 5–15 ms against an ALB. That
is acceptable for every product in this portfolio and would not be acceptable for an API under a
latency SLA. Recording the number means the `ALB → Gateway` swap §3 already describes has a
condition attached rather than remaining an open preference.

### Edge caching is the cheapest performance available

Cloudflare is in the request path and already paid for. `Cache-Control` on static assets and on
cacheable GETs moves more user-visible latency than any compute change, reduces origin load, and
therefore reduces replica count — performance and cost in the same move. It is unmentioned
everywhere else in this document and should be the first thing tried when a product is slow.

## 10. Policy baseline and lab isolation

Namespaces are not isolation. Without this, seven products in one cluster share a fate.

```
Pod Security Standards   restricted, enforced per namespace
NetworkPolicy            default-deny, then allow explicitly — `expose: cluster` (§4b)
                         renders the platform-namespace exception rather than hand-writing it
ResourceQuota            per namespace — one product cannot starve others
LimitRange               default requests/limits; nothing runs unbounded
ValidatingAdmissionPolicy  no :latest · no privileged · limits required
policy-controller        signed images only
```

`security-baseline` already provides SOC 2 *detective* controls. This is the preventive half.

**ValidatingAdmissionPolicy instead of Kyverno, and the reason is §2b.** That section lists four
components whose APIs pin the Kubernetes version, and every one of them is upgrade work a
two-person team will defer. ValidatingAdmissionPolicy is CEL-based, in-tree and GA since 1.30, and
it expresses the first three rules with no controller to run and nothing to upgrade. Image
signature verification is the one thing it cannot do, so Sigstore's `policy-controller` stays for
that alone.

Net effect: one fewer CRD-heavy controller on the upgrade path, and §2b's compatibility check drops
from four components to three.

### There is no multi-tenant hostile-code workload, and that is a deletion

Earlier versions of this section designed an isolation boundary for the IC lab — gVisor or Kata for
session pods, a tainted node pool, egress locked to a licence server, a dedicated cluster. **All of
it is removed**, because the requirement it served was withdrawn on 2026-09-12 (see §"The
decision"). The academy's practical work happens on physical workstations in a room.

That leaves the controls above serving their actual purpose: seven products that trust each other
moderately, written by the same three people. Namespace isolation, default-deny networking and
quotas are the right weight for that. **Nothing in this estate now runs code written by someone
outside the company**, which is a materially different threat model and should be stated so that
the next reader does not reintroduce sandbox machinery for workloads that do not need it.

If hostile-code multi-tenancy ever returns, it returns against physical hardware — which is a
different design, and the one case where §16's note about Rancher and owned hardware becomes
relevant rather than theoretical.

## 10b. Human access to the cluster

§10 covers what *workloads* may do. Nothing in the first draft covered what *people* may do, which
leaves the largest control in the system undefined — and §2 defers separate AWS accounts, so
cluster RBAC is carrying isolation work that account boundaries are not.

### Authentication: Entra through Identity Center, no IAM users

rova and opshub already authenticate against Entra (§4b), so the estate has an identity provider
and should not acquire a second one:

```
Entra → AWS IAM Identity Center → IAM role → EKS access entry → Kubernetes group
```

**EKS access entries, not the `aws-auth` ConfigMap.** The ConfigMap is the legacy mechanism, it is
edited in-cluster rather than in OpenTofu, and a malformed edit locks everyone out of the cluster
with no way back in. Access entries are an API, so they belong in OpenTofu under §7's rule: they
outlive a deploy.

No IAM users, no long-lived access keys. That is already the posture `security-baseline` enforces
for the root account, extended to everyone else.

### Four roles, and nobody has standing admin on production

| role | dev cluster | prod cluster |
|---|---|---|
| `platform-admin` | cluster-admin | **break-glass only — not standing** |
| `developer` | read all · logs · port-forward · exec | read all · logs. **No exec** |
| `read-only` | read | read — auditor and SOC 2 evidence |
| ArgoCD | its own service account; no human assumes it | same |

**`kubectl exec` on production is the control that matters most and is the easiest to leave
open.** An exec bypasses every audit trail this platform has: environment variables carry the
secrets ESO injected, the filesystem is writable, and nothing about any of it appears in git. A
platform whose entire promise is "the cluster is reproducible from git" (§13) has that promise
broken by one shell.

So `developer` has no `pods/exec` and no `pods/portforward` in prod. Debugging production is done
through logs, traces and profiles — which is what §9 spent six signals building, and which is the
point of having built them.

### Break-glass, designed to work when things are broken

```
a separate IAM role, assumable only by the two platform engineers
MFA required
CloudTrail alert on assumption → the same channel alerts go to
using it means writing an incident note afterwards. Not optional, not punitive
```

The alert is the control, not the permission. A break-glass role nobody can assume is a role people
route around during an incident; one that announces itself is a role that gets used honestly.

### Control plane audit logging

EKS control-plane logs are off by default, which means the record of who did what to the cluster
does not exist unless it is turned on before it is needed.

```
enable      api · audit · authenticator          (controllerManager and scheduler: not needed)
retention   90 days in CloudWatch
alert on    pods/exec · secret reads outside ESO's service account
            RBAC and ClusterRoleBinding changes · break-glass role assumption
cost        a few GB per month across both clusters — budget ~$15/month (§15)
```

These stay in CloudWatch rather than being shipped to Loki. EKS emits them there and nowhere else,
the volume is small, and adding a subscription filter plus a forwarder to move them is more moving
parts than the benefit justifies for two clusters.

### ArgoCD is the sharpest edge, for two reasons

**It holds credentials on both clusters** (§2). Its own access therefore needs the same treatment
as human access: SSO through Entra, and a `policy.csv` giving developers sync rights on dev and
read-only on prod. Nobody uses ArgoCD's admin account; it is disabled after bootstrap.

**And in GitOps, branch protection is a production access control.** Whoever can push to `gitops`
can deploy anything to production, because ArgoCD will faithfully apply it. That makes required
reviews on `gitops` a security control rather than a code-quality convention, and it should be
written down as one — including that the CI identity which bumps dev image tags (§11) must not be
able to write the prod values files.

### What this gives the SOC 2 conversation

Stated plainly, because §2 defers separate accounts partly on the grounds that SOC 2 will force the
issue later, and these controls are what carry the estate until then:

```
logical access       SSO, no shared accounts, no standing production admin
least privilege      four roles, exec removed from the one people use daily
audit                control-plane audit logs, 90 days, with alerts on the interesting verbs
separation of duties production changes require a reviewed pull request in `gitops`
```

## 11. Delivery

```
PR              tests · build · push to ECR with an immutable tag
merge to main   CI bumps the dev tag in `gitops` → ArgoCD syncs dev
promote         PR in `gitops` changing the prod tag → approval → ArgoCD syncs prod
rollback        revert that commit
```

Promotion becomes **a reviewable diff**. Today it is a version tag that applies whatever `main`
contains, which is why rova production ran code from before 7 September while `main` was 44
commits ahead — and why an alerting fix could not reach production without shipping nine
features.

Canary via **Argo Rollouts + Gateway API**, when wanted. Optional per product (`rollout.canary`).

### Image build and provenance

Three properties exist in the current pipeline and must survive the migration, because losing any
of them is a silent regression:

```
multi-arch      arm64 for rova and opshub; x86 for qnsc-kb, because clamav/clamav
                publishes no arm64 tag. Not a preference — a hard constraint.
build cache     GitHub Actions cache. Moved off the ECR `registry` backend on
                2026-09-13 after August's ECR bill was ~94% data transfer.
attestation     rova's deploy runs `Verify image attestation` before rolling. Keep it.
```

Kubernetes makes the last one **stronger** than it is today: Sigstore `policy-controller` can
require signed images cluster-wide (§10), so an unsigned image cannot run even if a pipeline is
bypassed. That is a policy boundary rather than a CI step, and it is worth the swap.

### Two tags, two lifecycles — and only production gets the second

A frequent question, and the answer is what makes §13's retention rules coherent rather than two
arbitrary numbers:

```
sha-<commit>   IDENTITY. Every build gets one. Immutable by construction — a commit
               hash cannot mean two things. This is what DEV deploys.
v<version>     LIFECYCLE. Applied only when an image is promoted to production.
               It is the record of the promotion decision, not a build artefact.
```

**Dev deploys `sha-` and never needs a `v`.** Dev redeploys on every merge to main; inventing a
version number for something superseded within hours adds a step and means nothing. The commit hash
is already unique, already traceable, and already in `gitops`'s git history — so "what was in dev
on Tuesday" is answered by that history, not by a tag.

### The same thing as a week

```
ECR holds ONE image. It can carry more than one tag. Promotion adds a tag;
it never rebuilds.

Mon 09:00  merge PR #201   CI pushes sha-a3f9c2e, bumps dev.yaml, ArgoCD syncs dev
Mon 14:00  merge PR #202   CI pushes sha-b7d1f40, dev now runs b7d1f40
                           (a3f9c2e stays in ECR, simply not deployed)
Tue 11:00  merge PR #203   sha-c2e8a91, dev now runs c2e8a91
Wed 10:00  ship            tag the EXISTING sha-c2e8a91 ALSO as v1.4.0
                           PR changes prod.yaml to v1.4.0 · review · merge
                           ArgoCD syncs prod — the exact bytes dev ran on Tuesday
Thu        rollback        revert that one commit. prod.yaml returns to v1.3.0
```

### Why production does not simply use `sha-` as well

It could, and many teams do. Two reasons not to:

**A retention rule can only see tags.** With `sha-` alone, ECR cannot distinguish an image running
in production from a build three months old, so the only safe policy would be keeping every build
for the full production window. Two prefixes make the split automatic.

**A version number is reviewable and a hash is not.** §11 promises that "promotion becomes a
reviewable diff". `- tag: v1.3.0 / + tag: v1.4.0` tells a reviewer something.
`- tag: sha-a3f9c2e / + tag: sha-c2e8a91` does not.

And the two retention rules then follow from the two lifecycles rather than being tuned:

```
sha-   keep the last 20            dev churn. Nobody rolls back dev by more than a few builds
v      keep 180 days (§13)         the production rollback window, stated in §13 as a promise
```

A promoted image carries **both** tags, so it matches both rules. The ECR module already handles
this — its own comment records that ECR applies the lowest `rulePriority`:

```
rulePriority 1   untagged   expire after 1 day
rulePriority 2   v*         keep 180 days      ← a promoted image lands here
rulePriority 3   sha-*      keep the last 20
```

**Promotion therefore moves an image from the short rule to the long one with no action required**,
because the image now matches a higher-priority rule. Nothing has to remember to do it.

### `:latest` is forbidden by this design and enabled in every repository today

```
rova/infra/live/_shared/main.tf:62       image_tag_mutability = "MUTABLE"  # allows re-tagging :latest
opshub/infra/live/_shared/main.tf:56     same
qnsc-kb-backend/infra/live/_shared:92    same
infra-template/live/_shared/main.tf:45   MUTABLE
```

This is not theoretical. `qnsc-kb-backend/infra/live/prod/main.tf:104` records where it already
went wrong: *"reset the task definition to whatever `:latest` points at — **which is a develop
build**."* A development image reached a production task definition through exactly this door.

An admission policy (§10) stops a pod from *naming* `:latest`. It does nothing about a tag moving
underneath a workload that is already running. Both halves are needed:

```
1  stop publishing :latest from CI            ← FIRST. Flipping the registry
                                                 first breaks the pipeline
2  image_tag_mutability = "IMMUTABLE"          ← then the registry refuses to
                                                 move any tag, ever
3  ValidatingAdmissionPolicy rejects :latest    ← already in §10
```

**The order matters and is the whole of the migration.** `IMMUTABLE` rejects a second push of an
existing tag, so a pipeline still publishing `:latest` fails on its next run. `sha-` and `v` tags
are unaffected because neither is ever republished.

§11c already requires `IMMUTABLE` on the chart repository. The image repositories need the same,
for the same reason: a pinned version that can be rewritten underneath you is not pinned.

## 11b. Local development

Developers keep **docker-compose**. No local Kubernetes.

A local cluster (kind, minikube, Tilt, Skaffold) is a meaningful amount of ceremony for a team
of two or three, and the preview environments above answer "does this work in a real cluster?"
far better than a laptop ever will — with the real chart, the real policies, and a real database.

This is written down because the alternative is each product answering it differently, and a
developer moving between rova and qnsc-kb then learns two local setups instead of one.

What must hold for this to stay true: **the container image is the only build artefact.** If a
service can only run under compose because of a host mount or a hard-coded localhost, it will
diverge from what ships. The preview environment is the check on that — if it works there, the
image is honest.

### Preview environments

```
ApplicationSet with a PR generator
  namespace     one per PR, deleted on merge or close
  hostname      *.preview.qnsc.vn → the SAME tunnel catch-all → Gateway
                → an HTTPRoute in the preview namespace. No per-PR tunnel edit.
  database      one shared "preview" Postgres, a database per PR, dropped on close
                NOT the dev instance — previews must not pollute dev data
  limits        5 concurrent · 72h TTL · auto-deleted
```

The wildcard hostname is what makes this work at all. Routing per PR is an `HTTPRoute` in the
preview namespace — an ordinary Kubernetes resource ArgoCD creates and deletes — rather than a
Cloudflare config change per pull request. This is the second problem Gateway API solves (§3), and
it arrives for previews rather than for canary.

Nearly free on ArgoCD, genuinely hard on ECS. For a small team reviewing across seven products,
"click the link on the PR" is worth more than most of the rest of this document.

**The second justification has nothing to do with reviewing a UI.** §6b records three messaging
bugs that were live in every deployed environment and invisible, and all three survived for one
reason: `scripts/localstack/01-bootstrap.sh` subscribed every queue, unfiltered, with raw delivery
on, while the Terraform did none of that. The local approximation was more generous than the
deployed topology, so dev could not reproduce prod and the bugs had nowhere to surface.

A preview environment removes that class of failure by construction rather than by discipline: it
is built from the manifest that reaches production, against real AWS resources, so there is no
second topology to drift from. Any test that runs there is testing the deployed shape. That is
worth more than the review link, and it is the reason previews belong in step 1 rather than in a
later phase.

## 11c. Chart versioning, and the blast radius of one chart

§5 states the rule that makes a single chart work: *"presets live in the chart and the module,
never copied into product repositories."* That rule is correct and it has a consequence the first
draft never addressed — **the chart becomes a dependency shared by every service in the estate, and
a bad version of it reaches all of them at once.**

§11 promotes *image tags* through a reviewable diff. It says nothing about promoting the chart
version that renders them, which means the most dangerous artefact in the system is the one with
no gate.

```
without pinning   push chart v1.3.0 → ArgoCD re-renders every Application
                  → 15 services get a broken manifest simultaneously
                  → and if the render drops a resource, auto-prune deletes it
```

### An application chart, not a library chart

§4 calls this "one Helm library chart". That should change, and the reason is boilerplate rather
than taste. A Helm chart of `type: library` exports templates and renders nothing on its own, so it
needs a wrapper chart per product — seven wrappers, each with its own `Chart.yaml`, `Chart.lock`
and a `templates/` directory whose only job is to call the library. That is seven copies of
something, which is the thing this document exists to prevent, and each wrapper is an escape hatch
where a product can quietly add a hand-written manifest.

An application chart plus one values file per (product, environment) has no wrapper and no escape
hatch:

```
gitops/charts/qnsc-service/          the chart. type: application
gitops/values/rova/base.yaml
gitops/values/rova/prod.yaml
```

The ArgoCD Application names the chart, the version, and the values files. Nothing else exists.

### The version is pinned per Application, and bumping it is a promotion

```yaml
# gitops/apps/rova-prod.yaml
source:
  repoURL: 608983206583.dkr.ecr.<region>.amazonaws.com
  chart: charts/qnsc-service
  targetRevision: 1.2.4          # pinned. Never a range, never a branch.
```

Chart published to ECR as an OCI artefact, semver, **with ECR tag immutability enabled on the chart
repository** so a version cannot be rewritten underneath a pinned Application.

A chart bump is then exactly the shape §11 already uses for images — a one-line diff in `gitops`,
reviewed and approved — and it rolls out in the same order §17 migrates products:

```
1  chart CI passes (below)
2  bump ONE dev Application — qnsc-kb dev, the lowest-stakes environment
3  soak
4  bump the remaining dev Applications
5  bump prod per product, rova last
```

Twelve Applications means twelve pins, which sounds like drift waiting to happen. It is the
opposite: a pin that is behind is *visible* in git, and a chart change that only some products have
taken is a state the system can be in deliberately rather than an accident.

### The test that matters is a rendered-manifest diff

Unit tests on a chart that renders fifteen services are necessary and not sufficient — the failure
to catch is "this change silently removes the PodDisruptionBudget from every size-M service", which
passes every unit test.

```
helm unittest        template logic
kubeconform          the output is valid Kubernetes for the target API version
golden render        `helm template` against EVERY values file, output committed,
                     CI shows the diff
```

The golden render is the control. **A chart pull request shows the exact manifest diff for all
twelve Applications**, so the reviewer sees what production will look like rather than reasoning
about what the template change implies. That is the same property §11 gives image promotion,
applied to the artefact that has more reach.

### ArgoCD guardrails

```
prod sync      gated by the promotion pull request, as §11 already specifies
auto-prune     ON for dev. For prod, never prune PersistentVolumeClaims or Namespaces —
               a bad render should fail, not delete
sync waves     CRDs and namespaces before workloads; migrations are PreSync (§4)
```

### The tension this creates, recorded rather than resolved

§14 argues for a monorepo on measured grounds: on 2026-09-13 `sanitizeString` could not be used
until `platform-http` was **published**, so two products kept duplicate copies. That publish-then-
consume tax is the core of the polyrepo argument.

**A versioned chart reintroduces exactly that tax**, one layer down. §5 says "if a preset does not
fit, the preset gains a field" — and now gaining a field means a chart release, twelve pins, and a
staged rollout before the product that needed it can use it.

Three things keep it tolerable, and they should be checked rather than assumed:

* The chart lives in `gitops`, which every engineer already touches. There is no separate
  repository to get access to and no package registry ceremony.
* The golden render makes review fast, because the reviewer sees output rather than templates.
* A product blocked on a chart release can pin the *new* version while others stay on the old one.
  The tax is paid by one product, not by the estate.

If that stops being true — if chart releases become a queue — the answer is not per-product escape
hatches. It is that the chart is doing too much and some of it belongs in values.

## 12. Cost attribution

TrueIDC pays the AWS bill today and may stop. Right now "what does opshub cost?" is
unanswerable — everything is one bill, and the only thing separating QNSC's spend from a
partner's is the `ManagedBy` tag.

```
cost allocation tags     product · env · size, activated in Billing
OpenCost                 per-namespace CPU/memory/storage attribution
one dashboard            cost per product per environment
```

Add this before migrating, not after. History cannot be reconstructed retroactively, and the day
the bill becomes QNSC's is the day two years of it becomes valuable.

## 12b. The day the bill transfers

§12 states the situation in one line: *"TrueIDC pays the AWS bill today and may stop."* Everything
in §15e is written as though cost reduction were a task. It is not — it is a **contingency**, and
the distinction changes what should be done now versus held in reserve.

### The subsidy window is an asset with an expiry

Three classes of work, and only one of them has lead time:

```
cost allocation tags   §12   lead time: FOREVER. History cannot be reconstructed
                             retroactively. A tag applied next year tells you nothing
                             about this year
measurement            §15d  lead time: two weeks of CloudWatch
the levers             §15e  lead time: about one week, and they are values changes
```

**Do the two with lead time now, while someone else is paying. Hold the levers in reserve.**

Optimising the bill today converts this team's scarcest resource — engineering hours — into
TrueIDC's savings. The correct use of a subsidy window is to buy the visibility that is cheap now
and impossible later, not to shave a bill that is not yours.

### Why the design survives the transfer

Every lever in §15e is a values change rather than a migration:

```
right-sizing              chart values
dev compute to zero       KEDA cron, chart values
prod all-Spot             capacity: spot — one field
Karpenter over Auto Mode  a provisioner swap; every manifest untouched
internal tools to zero    scaling.min: 0
no permanent dev          stop creating one
```

So the answer to "will this still be affordable when the bill lands" is that **the whole of tier 1
and tier 2 can be executed in about a week, reactively, with no re-architecture.** That property is
worth more than any individual saving, and it is the reason this design is defensible under an
uncertain funding arrangement. Nothing here traps the estate at a price.

### The tiers, as a contingency plan

| tier | what it gives up | 7 products | 3 products |
|---|---|---|---|
| **0** as designed, subsidised | nothing | $1,010 | ~$560 |
| **1** cost-conscious | nothing — measurement and Spot | $620 | ~$390 |
| **2** disciplined | internal tools cold-start; single replicas off the revenue path | $520 | ~$330 |
| **3** no permanent dev | a stable environment not tied to an open pull request | $350 | ~$250 |
| **4** floor | one cluster, prod only, Karpenter, free-tier observability | **~$340** | **~$220** |

**~$340 is the floor at seven products and it does not go lower on this platform.** Below it the
decision is not which lever to pull but which products to stop running — and that decision needs
per-product numbers, which is the whole argument of §12 arriving on schedule.

The floor is also not an argument for a different platform: §15 shows cost against Fargate is a
wash, so there is no cheaper AWS answer hiding behind this one.

### Two things this changes elsewhere

**Do not buy Savings Plans or reserved instances.** §15e previously recommended them after three
months of steady state, and that recommendation is **withdrawn**. The account (`608983206583`) is
QNSC's; TrueIDC is only the payer. A one-year commitment entered while someone else funds the bill
becomes QNSC's obligation the day that ends — and commitment pricing is precisely the wrong
instrument when the next move might be shrinking. Revisit when the funding question is settled,
not on a calendar.

**Ask TrueIDC which kind of ending this would be.** §2 records that QNSC is a member account in
organisation `o-cnvpmom3os`. Consolidated billing pools volume discounts and allows reserved
capacity to be shared across the organisation, so "TrueIDC stops paying" and "QNSC leaves the
organisation" are different events with different prices. The second may change effective rates on
top of changing who pays. Worth one email, and it affects the floor above.

### What to do this month

```
1  activate cost allocation tags           today — there is no way to buy this back
2  start the §15d measurement               two weeks, free, and it gates node sizing
3  build the per-product cost dashboard     §12 — the instrument needed on transfer day
4  nothing else                             the levers wait
```

## 12c. Stopping a product

§12b tier 4 says the quiet part: *"the decision is not which lever to pull but which products to
stop running."* This document has seventeen sections on adding a product and, until now, none on
removing one — which means a retired product keeps costing money in places nobody thinks to look.

With seven products and several of them speculative, this is not hypothetical.

### What a decommission actually touches

```
KUBERNETES     ArgoCD Application (dev and prod) · namespace · values files in `gitops`
               HTTPRoute · SLO recording rules and burn-rate alerts · dashboards
CLOUDFLARE     DNS records · tunnel route · Access policy · Pages project · R2 buckets
DATA           database and both roles on the shared instance, or the dedicated instance
               final snapshot, retained per the RPO the product had
SECRETS        Secrets Manager entries · ESO SecretStore · IRSA role and trust policy
IMAGES         ECR repositories — and their images, which retention will not remove
               because retention counts and ages, it does not notice abandonment
BILLING        cost allocation tags · the product's row in the §12 dashboard
QUEUES         SQS queues and DLQs · EventBridge rules · SNS subscriptions
```

**ECR is the one that bites**, because §13's retention rules expire by age and count, not by
whether anything still deploys the image. A retired product's repository sits there paying storage
until someone deletes it, and nothing in the design will ever flag it.

### The rule

**Deletion is a pull request in `gitops`, and OpenTofu removes the rest.** Both halves are
already how everything else works, so decommissioning is not a new mechanism — it is the same
mechanism run backwards:

```
1  remove the ArgoCD Applications → namespace and everything in it goes
2  take the final snapshot, and write down its retention date
3  `tofu apply` with the product's module call removed
4  delete the ECR repositories by hand — nothing else will
5  archive the repository; do not delete it
```

Step 2 before step 3 is the part to get right: `product-profile` destroying an RDS instance with
`skip_final_snapshot` would be unrecoverable, and the estate has already learned once what it
costs to destroy a database on purpose (§17).

**A quarterly check belongs in `alerting_health`:** any namespace, ECR repository, R2 bucket or
Secrets Manager entry with no corresponding entry in `gitops` is a finding. That is the only
thing that catches a half-finished decommission, and half-finished is the normal outcome.

## 13. Recovery, and a migration rule

State the promise rather than implying it from snapshot settings:

| size | RPO | RTO | mechanism |
|---|---|---|---|
| XS / S | 24h | 4h | daily snapshot, redeploy from git |
| M | 1h | 2h | PITR + redeploy |
| L (rova) | 5 min | 1h | PITR, Multi-AZ opt-in |

GitOps adds a property worth writing down: **the cluster is reproducible from git.** Losing one
becomes "recreate and let ArgoCD sync" — minutes, not a rebuild.

### That claim must be rehearsed, not asserted

"The cluster is reproducible from git" is the same *class* of statement as "alarms are
configured" — which was true of this account for weeks while every alarm topic had zero
subscribers. An untested recovery claim is decoration.

So: **delete the dev cluster and rebuild it from git. Time it. Write the number in this
document.** Repeat annually or after any change to the bootstrap path.

The rehearsal is also the only way to find what is *not* in git:

**Open — ArgoCD's own bootstrap.** Listed below as a known unknown since the first draft and still
unresolved: who installs the installer. Until it is answered the rebuild rehearsal cannot run, and
until the rehearsal runs the RTO figures above are estimates. The likely answer is a single
bootstrap script in `infra` that OpenTofu invokes after cluster creation — ArgoCD installing itself
from a manifest in `gitops`, then managing its own upgrades thereafter. It needs deciding, not
admiring.

```
PersistentVolumeClaims    RULE: no PVCs anywhere. With the `stateful` kind removed (§10)
                          nothing claims one, so Velero is not needed and the gap
                          closes by policy rather than by tooling
ArgoCD's own bootstrap    the chicken-and-egg: who installs the installer
Secrets                   values live in Secrets Manager, correctly — but ESO must be
                          installed and its IRSA role must exist before anything syncs
cluster-scoped resources  CRDs, Kyverno policies, StorageClasses
```

Until that rehearsal happens, the RTO figures above are estimates. Mark them as such.

### Rollback is a promise with an expiry date

§11 says rollback is "revert that commit". That is only true while the image the reverted commit
names still exists, and `tf-modules/modules/ecr` expires images by **count**, not by time:

```
keep_release_count   30      release images (v*)
keep_build_count     20      build images (sha-*)
untagged_expire_days 1
```

Thirty releases is a duration only if the deploy rate is known, and GitOps raises it — the whole
point of §11 is that promotion stops being a batch of forty-four commits. So the rollback window
shrinks precisely as deploys get healthier, silently, and the failure surfaces at the worst
possible moment.

**State the promise in the unit people reason in, then make the policy match it:**

```
promise      any release from the last 180 days can be rolled back to
release rule sinceImagePushed / 180 days   — NOT imageCountMoreThan
build rule   keep 20 — unchanged; these are dev-only
untagged     1 day — unchanged
```

180 rather than 90 because the risk is asymmetric: keeping an image costs about a dollar a month,
and not having one costs a rollback at the moment a rollback is needed. The number wants to be
generous enough that it is not the binding constraint today, and to stay correct as the promotion
rate rises.

**A time rule can delete what a count rule was keeping, and the direction depends on the current
promotion rate** — at a low rate, thirty releases may span more than 180 days. So this is applied
only after `aws ecr start-lifecycle-policy-preview`, which the module's own comments already
establish as the procedure. If the preview expires a release worth keeping, raise the number; do
not lower it to match whatever the count rule happened to retain.

Retention is not where the money is. ECR storage is $0.10/GB-month, and August's ECR bill was ~94%
*data transfer* (§3), which the S3 gateway endpoint addresses. There is no cost argument for a
short rollback window.

The module already gets the hard part right — separate rules per tag prefix, after the discovery
that `tagPrefixList` is AND rather than OR and that 105 images sat under a policy claiming to keep
30. This is a unit change on top of a correct design. **Written, not applied:**
`tf-modules/modules/ecr` now takes `release_retention_days` in place of `keep_release_count`, and
`qnsc-kb-backend/infra/live/_shared` is updated to match. It ships as its own reviewed change with
the preview output attached, because it alters expiry behaviour on live repositories.

**And rehearse it.** The rebuild drill below tests that the cluster comes back. It should also test
that a rollback works: revert a commit from the far end of the window and confirm ArgoCD syncs an
image that still exists. An untested rollback promise is decoration in exactly the way an untested
recovery claim is.

### Secrets are regenerated, not restored

Secrets Manager values are written out of band (§8), which means they are backed up nowhere — and
that is correct, because most of them cannot be restored anyway. A rotated Grafana token is not a
thing you recover from a backup; it is a thing you re-mint.

So §8's inventory carries **provenance** rather than a backup: which system issues each value, and
what the re-issue procedure is. Set Secrets Manager's deletion recovery window to 30 days for
accidental deletion, and treat regeneration as the recovery path for everything else.

**Expand and contract.** A release may add columns or tables. Dropping or renaming happens in a
*later* release, after the previous version is fully retired. Never both in one deploy — a
rollback after a destructive migration is unrecoverable, and rollback is the main thing GitOps
promises.

## 14. Two decisions, and their reasoning

Both were left open in the first draft and are now settled. Recorded with reasoning rather than
as bare choices, because the reasoning is what a future reader needs in order to disagree
usefully.

### Monorepo: decided against for now, and the reasoning kept

**Every repository stays where it is.** rova, opshub, app-platform, qnsc-kb-backend,
qnsc-kb-frontend and solodesk remain separate, exactly as today. This section records why a
monorepo was considered and why it is not being done, because the argument is sound and whoever
revisits it should not have to reconstruct it.

**The measured case for it.** On 2026-09-13 `sanitizeString` was extracted into `app-platform`, and
rova and opshub could not use it until `platform-http` was **published**. The duplication is still
there and still verifiable:

```
app-platform/packages/platform-http/src/http/sanitize.ts     the shared one
rova/libs/platform/src/utils/sanitize.util.ts                a copy
opshub/libs/platform/src/utils/sanitize.util.ts              another copy
```

Fixing a bug in it today is four steps across three repositories — edit, publish, bump rova, bump
opshub — with a window in which the three disagree. In a monorepo it is one commit. That
publish-then-consume tax is the polyrepo cost and it is paid on every shared change.

**Why it is not being done anyway.** Three reasons, and the third is decisive:

* **It is unrelated to this platform.** §1 states it: *"the platform sees services, not
  repositories."* The chart deploys an image named `rova-api`; where its source lived when the
  image was built is invisible to the cluster. Kubernetes and the repository layout are entirely
  separable decisions.
* **It costs one to two weeks** — merging repositories with history intact, plus Nx or Turborepo
  for affected-only CI, without which a monorepo tests everything on every commit and the
  productivity gain inverts. That is scope added to a platform already at 12–16 weeks (§18).
* **The case was always weak.** An earlier draft put it at "roughly 60/40 in favour." A 60/40 call
  worth one to two weeks, with no bearing on the migration, is not one to spend a quarter's
  goodwill on. The duplicated `sanitizeString` is annoying; it is not causing outages, and it will
  still be fixable in a year.

**One clarification worth recording, because it caused repeated confusion.** A monorepo would not
have merged the products. One repository is not one product, one image, one release or one
deployment:

```
                              today                    monorepo
Docker images       rova-api · opshub-api          unchanged
databases           separate                       unchanged
namespaces          rova · opshub                  unchanged
ArgoCD Applications one per product per env        unchanged
deploys             independent                    still independent
releases            independent versions           still independent
```

Only the location of source files in git would have changed. Everything downstream of the build is
identical either way — which is also precisely why the change is optional.

**Revisit when** the platform is quiet and shared code is changing often enough that the publish
step is a weekly irritation rather than an occasional one. The two structural exceptions hold
whenever that happens: **solodesk stays out** (Xcode, Gradle, Fastlane, code signing, macOS
runners — no shared tooling, caching or dependency graph), and **any Go product stays out** for the
same reason (§4d). `contracts` would be its own repository regardless, since `.proto` files are
consumed by every language.

### EKS Auto Mode

AWS manages nodes, AMIs, patching and upgrades, at roughly a **12% premium** on node cost.

**The number in the first version of this section was wrong by 4.7×.** It said "about $12/month on
~$100 of nodes", and ~$100 was the node figure from the us-east-1-priced model §15 has since
replaced. Re-priced against ap-southeast-1 with a realistic overhead allowance, nodes are **$468**,
so the premium is **$56/month** — not the cheapest thing in this document but the fourth-largest
line in it, after compute, control planes and RDS.

The reasoning survives the correction and the conclusion is unchanged, but it is now a real trade
rather than a rounding error:

```
keep Auto Mode    $56/month buys never rotating an AMI or sequencing a node upgrade.
                  With three engineers this is exactly the class of work that gets
                  deferred until it becomes an incident.
take Karpenter    $56/month back, and node lifecycle becomes ours. Karpenter's own
                  advantage — control over instance families — is worth something now
                  that §15 shows instance CHOICE matters: c7g packs this estate's
                  2.6 GiB-per-vCPU shape better than m7g does.
```

**Keep Auto Mode.** Half a day of node-upgrade work per quarter costs more than $56, and §2b
already records that upgrade work is the first thing a two-person team defers. But re-decide this
after §15d, when the node bill is measured rather than modelled — if right-sizing takes nodes to
$250, the premium falls to $30 and the trade gets easier, not harder.

**Revisit if a GPU workload arrives.** The original trigger was the IC lab's EDA instance
families; that lab is withdrawn (§10), so the remaining candidate is Axis 3's `resources.gpu` —
self-hosted inference for the LMS, or moving qnsc-kb's embeddings off CPU. Verify against Auto
Mode's supported families at that point; if it does not fit, Karpenter on EC2 for that node pool
only. The workloads are unchanged either way — only the provisioner differs.

### Both are reversible

Polyrepo → monorepo is a repository merge, and back again is a split. Auto Mode → Karpenter is
swapping a node provisioner and leaves every manifest untouched. Neither is a one-way door, which
is why they were worth deciding rather than deliberating — and why deferring the first one costs
nothing.

## 15. Cost, honestly

August 2026, measured, three products across two environments:

```
 37.35  RDS          31.23  ECR            24.30  ECS Fargate
 24.23  ElastiCache   6.19  Tax             6.10  EC2 (fck-nat)
  6.04  VPC           3.39  Secrets         2.91  CloudWatch      2.01  KMS
────────
150.56  TOTAL
```

### Two earlier models were wrong, and the second was wrong in a way that flattered the decision

The first scaled three products' bill up to seven and concluded Kubernetes cost $190–290/month
more. That method was invalid: Fargate bills per task and does not bin-pack, so its compute line
grows with service count rather than staying near $80.

The second recomputed from resource requests and concluded Kubernetes was **$220/month cheaper**.
Its method was sound and it had two defects, both checkable:

* **It priced an ap-southeast-1 estate at us-east-1 rates.** Its Fargate line read
  `16 × $0.04048 + 40 × $0.004445`. Those are the us-east-1 per-vCPU-hour and per-GB-hour figures.
* **It converted requests to nodes with no overhead allowance** — nothing for kube-reserved,
  eviction thresholds, DaemonSets, or the spare capacity a rolling update needs.

The first defect inflates both columns equally and is harmless to the comparison. **The second
inflates only the EKS side's efficiency**, and it is the one that produced the $220.

### Unit prices, ap-southeast-1

List prices, September 2026. Verify against the AWS calculator before committing capital; the
conclusion below is robust to ±15% but the absolute figures are not.

```
Fargate         $0.04856 / vCPU-hr · $0.00532 / GB-hr     (x86; Graviton ~20% less)
Fargate Spot    ~70% off on-demand
EKS control     $0.10 / hr = $73 / month / cluster
m7g.xlarge      4 vCPU / 16 GiB    $0.1904 / hr      Spot ~$0.0666
m7g.2xlarge     8 vCPU / 32 GiB    $0.3808 / hr      Spot ~$0.1333
c7g.2xlarge     8 vCPU / 16 GiB    $0.3370 / hr      Spot ~$0.1180
EBS gp3         $0.096 / GB-month
db.t4g.micro    $13.14 / month     small $26.28 · medium $52.56
```

us-east-1 is 17–20% cheaper on every line above. That difference is the whole of the first defect.

### Requests, bottom-up from the live OpenTofu

Not estimates. These are the allocations currently deployed, plus the four products not yet built:

```
PROD    rova api 2×0.25/1.0 · worker 2×0.25/0.5                    1.00 vCPU /  3.0 GiB
        opshub api 2×1.0/2.0 · worker 1×0.5/1.0                    2.50      /  5.0
        qnsc-kb api 2×1.0/4.0 · worker 1×2.0/5.0 · beat            4.10      / 13.3
        LMS · solodesk · ai-dev-kit                                 2.75      /  5.5
        clamd 2×0.5/2.5                                            1.00      /  5.0
        system — ArgoCD, Alloy ×2 tiers, ESO, cloudflared,
                 Gateway, KEDA, CoreDNS, OpenCost                   3.40      /  6.7
        ──────────────────────────────────────────────────────────────────────────────
                                                                  ~15 vCPU  / ~39 GiB

DEV     qnsc-kb (2048/8192 api · 4096/8192 worker)                  6.00      / 16.0
        everything else + system                                    5.00      / 11.0
        ──────────────────────────────────────────────────────────────────────────────
                                                                  ~11 vCPU  / ~27 GiB
```

**qnsc-kb dev alone is more than half of dev**, which is why §15d puts it first.

### The comparison, re-priced

Both columns state their Spot assumption, because that assumption turns out to decide the answer.

| | ECS Fargate | EKS + Auto Mode |
|---|---|---|
| Spot assumption | prod 75% on-demand — matches today's `use_spot = false` on rova api, opshub api and worker, qnsc-kb api. Dev all Spot | prod `capacity: mixed`, on-demand floor of one node. Dev all Spot |
| prod compute | **$485** | **$311** — 2 × c7g.2xlarge Spot + 1 × m7g.xlarge on-demand |
| dev compute | **$127** | **$157** — c7g.2xlarge + m7g.xlarge + c7g.large, all Spot |
| control planes | $0 | $146 |
| Auto Mode premium | — | $56 |
| EBS | — | $12 |
| RDS¹ | $195 | $91 |
| ElastiCache | $38 | $24 |
| ECR · VPC · Secrets · KMS · CloudWatch² | $46 | $61 |
| Grafana Cloud | $50 | $75 — six signals, §9d. **Free today; see below** |
| tax ~8% | $75 | $77 |
| **total** | **~$1,016** | **~$1,010** |

¹ RDS differs because §5's layout is a Kubernetes-side decision in practice — nothing stops ECS
from sharing instances, but it never did. Credit it to the platform only if it actually ships.

² EKS is higher by the control-plane audit logs of §10b.

### The honest conclusion: cost is a wash, not a driver

**At seven products in Singapore, the two platforms land within about $50/month of each other** —
inside the error bar of every estimate in this section. The $220 advantage does not survive
re-pricing.

The sensitivity is almost entirely one variable:

```
if EKS runs prod ALL-Spot           EKS ~$920    — $95 cheaper
if EKS keeps a large on-demand floor EKS ~$1,100  — $85 more expensive
```

Bin-packing is not the lever the earlier model thought it was. At fifteen services the packing gain
is roughly cancelled by the $146 control-plane floor plus the ~25% of node capacity that
kube-reserved, DaemonSets and rolling-update headroom consume. **What remains is that Kubernetes
lets you run more of the estate on Spot safely** — a PodDisruptionBudget, a drain and multiple
replicas make a reclaim a rescheduling event, where on Fargate it is a dropped task. That is a real
advantage and it is worth roughly $100/month, not $220.

**So cost should be removed from the list of drivers in §"The decision".** It is not an argument
against Kubernetes — break-even at equal capability is a perfectly good result — but it is not an
argument for it either, and after the IC lab was withdrawn the platform decision now rests on
consolidation (one chart, fifteen services), heterogeneity of product shape, and preview
environments. Those three are sufficient. Cost is not load-bearing and should not be asked to be.

### Where this is still uncertain

**Allocations are not usage.** Every request figure above is what the task is *allocated* on ECS
today, and §15d exists because allocation is typically 2–3× measured p50. Right-sizing moves the
EKS column further than the Fargate column, because EKS pays for provisioned nodes while Fargate
pays for declared task size — a 40% cut in requests takes roughly $180/month off EKS and $190 off
Fargate, so it improves both and does not change the ranking.

**Reserved capacity is unmodelled, and deliberately so.** A one-year Compute Savings Plan would
take ~27% off the on-demand portion of either column. §12b explains why it is not being bought:
the account is QNSC's but TrueIDC pays the bill today, and a one-year commitment made under someone
else's funding becomes QNSC's obligation the moment that changes.

**On timing — see §18.** The "6–10 weeks" this section used to carry was written against a much
smaller design and is no longer credible.

### 15b. What the rest of this document takes off that number

The table above compares *platforms*. It does not include the decisions made elsewhere in this
document, each of which is a values change or a one-time setting rather than a different
architecture:

| change | §  | monthly | confidence |
|---|---|---|---|
| dedicate rova and qnsc-kb in prod, share the rest, share all of dev | 5, 5d | −$40 | high — arithmetic on measured instance prices |
| ElastiCache consolidated to one instance per environment | 5d | −$8 | high |
| clamav split out, qnsc-kb moves to Graviton | 4c | −$35 | high |
| S3 gateway endpoint for ECR pulls | 3 | −$15 | high — already billed once |
| `trafficDistribution: PreferClose` | 9j | −$12 | medium |
| KEDA scale-to-zero on dev workers | 4b | −$20 | medium |
| VPA-recommended right-sizing | 15d | −$75 | medium — needs a month of data |
| EKS control-plane audit logs | 10b | **+$15** | an addition, not a saving |
| | | **−$190** | |

The database line was **−$89** in an earlier version. That figure was measured against "every
product dedicated in both environments", which is what the estate does today but not what anyone
would choose starting fresh. Against the sensible alternative — dev shared, prod dedicated — the
gap is $40, and §5 explains why the decision was then made on restore granularity rather than on
the money.

### These subtract from the re-priced §15, not from the old one

§15 is now built bottom-up at ap-southeast-1 prices and already contains the database layout, the
ElastiCache consolidation, the Graviton move and the audit logs. **The table above is therefore a
ranking of levers, not a further deduction from `~$1,010`** — double-counting it would subtract the
same decisions twice.

What remains genuinely outstanding against §15's figure is the right-sizing line, because §15 is
priced on *allocations* rather than measurements. §15d is how that gets collected.

### The number that will actually be asked about

Migration complete with today's three products is roughly **$840/month**, against **$150.56**
measured in August. That looks like a 5.6× increase and mostly is not.

```
things that exist but are not currently running    ~$550
  opshub prod never launched · qnsc-kb prod has no state file ·
  every dev service sits at min_count = 0 with databases stopped 52% of the week
Kubernetes overhead proper                         ~$200
  two control planes, a node floor Fargate bills at zero, the Auto Mode premium
observability, free tier to six signals             ~$75
```

Only the middle figure is attributable to this design. The $550 is owed the moment opshub and
qnsc-kb production actually launch, on either platform. **August's $150.56 is not a baseline — it is
the cost of a partially deployed estate**, and comparing against it will make this migration look
like something it is not.

Two items are hard to retrofit and therefore belong at step 1 of §17 rather than in a later
optimisation pass: **the database layout** is a data migration once products are live, and **KEDA**
means unwinding fifteen HPA configurations if it arrives second.

### Right-sizing is the largest recurring lever, and it is free

Bin-packing bills by *requests*, and §15 already concedes the per-service requests here are
"estimates rather than measurements". Teams routinely over-request by two to three times, which on
$250/month of compute is $100–150 of paid-for idle.

```
VPA in recommendation mode ONLY — never auto, which fights HPA over the same metric
read the recommendations monthly, update chart values, commit the diff
```

It costs one controller and a recurring half hour. It is the highest-value cost activity that
exists once the platform is running, and unlike everything else in this table it keeps paying as
the estate grows.

### 15d. Measure before sizing — the protocol

Every number above is a list price applied to an estimate, and §15 says so itself. That was a
tolerable weakness when the IC lab was a hard scheduling requirement that ECS could not meet. **It
is no longer tolerable: with the lab withdrawn, cost is the primary quantitative justification for
this entire migration** (§"The decision"). The argument now stands or falls on numbers nobody has
measured.

The data already exists and does not require the platform to be built. `AWS/ECS`
`MemoryUtilization` and `CPUUtilization` are percentages **of the allocated task size**, and the
allocations are in the live OpenTofu — qnsc-kb's api at `1024/6144`, its worker at `2048/6144`, and
so on:

```
two weeks of history, per service, per environment:
  p50   → the request. This is the bin-packing unit, so it is the bill.
  p95   → the memory limit
  peak  → sanity-check against the allocation currently paid for
```

Do qnsc-kb first. It is roughly half of both environments, so its real numbers move the total more
than everything else combined, and §15 already concedes the estimate depends on it most.

### Why "start minimal and let it autoscale" is only half right

The instinct is correct for two of three things and expensive for the third, and the three get
conflated because they all sound like scaling:

```
pod SIZE       set from measurement. NOT minimum.
replica COUNT  yes — start at the floor and autoscale. Axis 7, KEDA, min: 0 for workers.
node COUNT     yes — Karpenter consolidation already does this, with no configuration.
```

Replica count and node count are already built to that instinct. Pod size inverts it, because
**Kubernetes schedules on requests, not on usage:**

```
under-request CPU      the scheduler packs ten pods onto one vCPU. CPU is compressible,
                       so they throttle rather than crash — latency degrades with no
                       OOMKill, no restart and no alarm. Close to undiagnosable without
                       the profiles §9c adds.

under-request memory   memory is NOT compressible. Either the pod is OOMKilled, or it
                       borrows from the node and a correctly-sized NEIGHBOUR dies when
                       the node fills. The second is worse, and it looks random.
```

**An HPA cannot rescue an under-sized pod.** It adds replicas, not size: a pod that needs 2 GiB
and was given 256 MiB still OOMKills six times over. HPA answers "too much traffic for N pods",
never "each pod is too small". VPA can resize, but not in auto mode beside an HPA — they contend
for the same signal, which is why §15b specifies recommendation mode only.

So guessing low is not free. It trades a node you can price for latency and OOMKills you cannot.
That is why this section says *measure* rather than *estimate low* — the error is expensive in
both directions.

**Dev is the exception, and the instinct fully applies there.** A slow dev pod costs nothing, so
§5b sets low requests deliberately.

### Requests and limits: the rule, which is not the obvious one

```
CPU      request only. NO LIMIT.
memory   limit == request.
```

**CPU limits throttle on bursts, not on averages.** The CFS quota is enforced per 100 ms period, so
an IO-bound service averaging 20% CPU with 100 ms request spikes is throttled hard at a 500m limit
— and it presents as latency with no visible CPU pressure, which is close to undiagnosable without
the profiles §9c adds. Every service in this portfolio is that shape: NestJS on Fastify, and
FastAPI.

**Memory is the opposite, because it is not compressible.** Letting a pod burst above its request
only defers an OOMKill to a less convenient moment, and it breaks the bin-packing the cost model
assumes. Setting `limit == request` also gives the pod Guaranteed QoS, so it is evicted last under
node pressure — which matters specifically because §5b runs dev deliberately hot with low requests.

After the platform exists, VPA in recommendation mode (§15b) maintains these numbers. This protocol
is how they start out right rather than being corrected for a year.

### 15e. The levers that remain, ranked

§15 prices the design as specified. These are what is left on the table, against its ~$1,010.

| lever | saves | effort | § |
|---|---|---|---|
| **right-sizing from measurement** | **~$168** | two weeks of CloudWatch, then a values diff | 15d |
| **dev compute scaled to zero outside hours** | **~$70** | KEDA cron scaler, already a dependency | 5b |
| prod all-Spot rather than an on-demand node | ~$50 | PDB and drain discipline | 15 |
| Karpenter instead of Auto Mode | ~$35 | own node lifecycle | 14 |
| ~~Compute Savings Plan~~ | ~~$38~~ | **blocked — a one-year commitment while the funding arrangement is unsettled. See §12b** | 12b |
| ~~RDS reserved instances~~ | ~~$20~~ | **blocked, same reason** | 12b |
| Aurora Serverless v2 dev, 0 ACU floor | ~$16 | already designed | 5d |
| dev Valkey as a pod rather than ElastiCache | ~$12 | none — losing a dev cache on restart costs nothing | 5d |

They compound, because right-sizing shrinks what every percentage below it applies to:

```
$1,010  →  $842   right-sizing
        →  $772   dev compute to zero outside hours
        →  $722   prod all-Spot
        →  $687   Karpenter
        →  $659   Aurora dev + dev Valkey pod
        →  $659   (Savings Plans and RIs withheld — §12b)
```

**Roughly $620–700, from $1,010.** About 35%, and none of it requires a different architecture.

### Only two of those clear the bar

**Measure first.** Every request figure in §15 is an ECS *allocation*, and allocation is typically
two to three times measured p50. qnsc-kb dev is allocated `2048/8192` and `4096/8192` — 6 vCPU and
16 GiB, more than half of the dev environment — and nobody has checked what it uses. It is free, it
is two weeks of waiting, and it is worth more than everything below it combined.

**Then dev compute to zero**, on the reasoning in §5b's reopened subsection: the incident that
blocked this was about databases, and databases are now handled by Aurora Serverless v2 instead.

Together that is about **$240/month for roughly a week of work**, and neither is a commitment that
cannot be reversed.

**Then stop.** Going from $650 to $600 costs engineer-days worth more than the annual saving. The
Savings Plans and reserved instances look like free money — paperwork rather than engineering —
and **§12b withdraws that recommendation entirely for now.** A one-year commitment is the wrong
instrument while it is unclear who will be paying the bill in twelve months.

### Second tier — smaller, and two of them trade availability

Against the ~$619 the first tier reaches:

| lever | saves | the catch |
|---|---|---|
| prod scale-to-zero for internal tools | ~$35 | opshub has no traffic at night. KEDA HTTP trigger, 30–60s cold start. Nothing in the `platform` namespace may scale to zero — clamd is on qnsc-kb's upload path (§4c) |
| 1 replica for internal tools, not 2 | ~$25 | accepts ~30s of downtime during a node drain. Fine for opshub and ai-dev-kit, not for rova |
| fewer, larger nodes | ~$15 | Alloy is a DaemonSet: 3 × `m7g.2xlarge` runs three copies, 6 × `m7g.large` runs six. Node *shape* changes system overhead |
| trim system overhead in dev | ~$15 | Gateway 2→1, cloudflared 3→2, Alloy gateway 2→1, OpenCost prod-only. System is roughly 20% of all requests |
| Grafana Cloud may be free | up to $75 | §15 budgets $75. With §9d's cardinality discipline fifteen services may fit the free tier — measure the series count before paying for it |

**Roughly $500–540.** The Grafana line is the only one worth chasing eagerly, because it costs
nothing to check and might be the largest item in the table.

### Components worth deleting, not tuning

The largest remaining savings are not tuning. They are asking whether a component earns its place
at this team size — and two do not obviously.

**Grafana Cloud is on the free tier today, and §15 budgets $75 anyway.** That $75 is a provision
against six signals across fifteen services, not a measurement, and the two are very different
claims. The check is one query after the first cluster runs:

```
count the active series · count log GB/day · count trace GB/day
compare against the plan's included volume BEFORE paying for it
```

§9d's discipline — Adaptive Metrics, a four-label ceiling on Loki, tail sampling, `/health` logs
dropped — exists precisely to keep this inside the free tier. **If it works, this is the largest
single line in §15e and it costs nothing to find out.** Treat $75 as a ceiling to defend, not a
bill to accept.

**Feature flags — decided, and the answer was deletion.** An earlier version of this section asked
whether a self-hosted Flagsmith earned a pod, a database on the shared instance and a slot in
§2b's upgrade path. §4c settles it: **OpenFeature in the applications, ConfigCat as the provider,
nothing in the cluster.** Worth about $20/month, one fewer component to upgrade, and the whole of
§5c's cross-environment analysis disappears with it.

**OpenCost.** §12 wants per-namespace attribution. AWS cost-allocation tags plus a Grafana query
over the Cost and Usage Report delivers most of it with no pod and no component in the upgrade
path. Marginal money, one less moving part.

### Two splits already taken, and the principle behind them

**The static frontends are already off the platform.** rova and opshub both build `apps/web` with
Vite and React, and neither declares a `web` service in its ECS stack — they deploy through
`modules/pages-web` to Cloudflare Pages, and qnsc-kb's frontend is its own repository doing the
same. §15's request tables only ever counted `api` and `worker`, so there is no hidden line to
remove here. It is recorded so the next reader running this exercise does not redo the analysis.

**LMS is smaller than §15 models it.** §15 sizes it as a generic M product at 2 vCPU / 4 GiB. Per
its own plan it is `learning-{api,worker,web}` where web is Vite on Pages, transcoding is
**MediaConvert** (~$18 per 40-hour course, not a pod), and delivery is R2. Realistically 1.5 vCPU /
3 GiB — about **$15/month**, and worth correcting mostly because this document should not model a
product as larger than its own plan says it is.

### And the principle: do not split across platforms

The frontends work as a split because a Vite build has **no runtime** — it is a build artefact on a
CDN, not a deployment pattern.

Everything else is different. Putting ai-dev-kit on Lambda, workers on Fargate and small services
on Workers produces three or four deployment patterns for three engineers, **which is the
seven-copies problem this platform exists to remove, wearing different clothes.** §4b's argument is
that adding an architecture means adding a service to a values file; every "except this one runs
elsewhere" is a tax on that, paid in the currency this team has least of.

The control plane is worth $146/month precisely because it is *one* chart. Split enough off it and
the floor is still paid without the thing it buys.

### The structural lever, which is larger than any of the above

**$1,010 is a seven-product figure and four of those products do not exist.** The bill arrives as
they launch, not before, so the most effective cost control is asking whether each one needs a
production environment at the moment it launches — rather than provisioning one because the design
makes it easy.

ai-dev-kit is an internal team tool. Does it need a production environment, or is it a preview
environment somebody keeps alive? That question, asked once per product, is worth more than every
line in both tiers.

### Where to stop

```
as designed                                         ~$1,010
+ measure (§15d) and dev compute to zero (§5b)        ~$770     ~1 week
+ prod all-Spot, Karpenter, Aurora dev                ~$660     2-3 days
+ the second tier above                               ~$520     3-4 days
```

The first two lines are clearly worth it. **The third is where to stop asking.** It is three or
four engineer-days for about $140/month — it pays back inside a year, but only if nothing breaks,
and two of its levers trade availability on systems this team depends on daily.

Below roughly $500 the remaining levers stop cutting waste and start cutting reliability. At that
point the correct move is not another lever — it is launching the four products that justify the
platform.

### The aggressive option, named but not recommended yet

**Delete the permanent development environment.** §11's preview environments already give a real
namespace with real AWS resources per pull request, built from the manifest that reaches
production.

```
dev cluster control plane   −$73
dev compute                 −$157
dev database and cache      −$40
                            ─────
                            −$270      →  roughly $400/month
```

What it costs is a stable place for integration testing, manual QA and demos that is not tied to an
open pull request. For three engineers that may genuinely be fine. It is a workflow change rather
than a configuration change, so it should only be considered after living with preview environments
for a quarter — and it is recorded here so that the option is remembered rather than rediscovered.

### 15c. What breaks first

"Will it scale" is not a yes or no; it is a list with triggers. In the order these actually arrive:

| # | arrives at | presents as | fix | § | cost |
|---|---|---|---|---|---|
| 1 | ~10 services with autoscaling | Postgres connection exhaustion | PgBouncer | 5d | $0 |
| 2 | ~15 services plus Alloy | pods stuck in `ContainerCreating`, no obvious cause | /20 subnets + prefix delegation | 3 | $0 |
| 3 | first month | Grafana bill jumps, traffic unchanged | Adaptive Metrics, label discipline | 9d | $0 |
| 4 | grows with service count² | cross-AZ transfer, attributable to nothing | `trafficDistribution: PreferClose` | 9j | $0 |
| 5 | **already happened** | ECR bill is 94% data transfer | S3 gateway endpoint | 3 | $0 |
| 6 | real traffic on rova | shared instance CPU saturation | rova is already dedicated | 5d | — |
| 7 | ~50+ Applications | ArgoCD reconcile latency | not a concern at 12 | 5c | — |

Five of the seven are free, and all five arrive before anything in this estate becomes large. That
is the honest answer to whether this design scales: the first five failures are known, cheap, and
addressed above — and the sixth and seventh are far enough out to be somebody's later problem.

## 16. Deliberately excluded

* **Rancher** — manages *many clusters, in many places*. Two managed clusters in one account make
  it pure overhead. The old revisit trigger was the IC lab on owned hardware; that lab is
  withdrawn (§10), so there is no trigger left and this is now a plain exclusion.
* **Service mesh** — fifteen services does not need an mTLS mesh.
* **Kafka** — SQS is sufficient; `ARCHITECTURE_FUTURE_SCALE.md` gates it at Stage 3.
* **Self-hosted LGTM** — see §9.
* **Crossplane** — see §7.
* **Multi-region** — no customer requirement yet.
* **Self-hosted feature flags** — see §4c. OpenFeature in the applications, ConfigCat as the
  provider, nothing in the cluster. LaunchDarkly excluded on pricing shape; `flagd` is the
  recorded exit if the subscription or the residency answer ever makes it necessary.
* **Per-product Redis** — see §5d. One shared instance per environment, database index per
  product. Redis itself stays: it is qnsc-kb's Celery broker and rova and opshub's shared cache.
* **Kafka, RabbitMQ and NATS JetStream** — see §6b. SQS for work queues, EventBridge for
  cross-product events, and the transactional outbox for everything inside one database.
* **Service mesh** — still refused, and now for a specific reason: gRPC load balancing is the usual
  trigger, and a headless Service with client-side `round_robin` answers it (§4d).
* **Kyverno** — replaced rather than excluded: ValidatingAdmissionPolicy covers the rules and
  Sigstore `policy-controller` covers signatures, with one fewer controller to upgrade (§10).
* **Local Kubernetes** — see §11b. docker-compose plus preview environments.
* **Auto-mode VPA** — recommendation mode only. Auto VPA and HPA fight over the same metric (§15b).

## 17. Migration order

| # | step | why here |
|---|---|---|
| 0 | S3 gateway endpoint · subnet resize to /20 · prefix delegation | free, no cluster required, and §15c items 2 and 5 have already cost money |
| 1 | EKS ×2 · ArgoCD · Alloy two-tier · ESO · KEDA · policy baseline · shared Postgres + PgBouncer · **access entries and audit logs (§10b)** · **chart CI and pinning (§11c)** | foundation — no external dependency. KEDA and the shared database are here because both are painful to retrofit (§15b); access control and chart pinning because retrofitting either means doing it while something is already broken |
| 2 | **qnsc-kb dev**, with clamav split into `platform` | first workload. Prod has no state file, so dev is genuinely low-risk — and it proves more of the chart than anything else could |
| 3 | **qnsc-kb prod** | after dev has soaked |
| 4 | **LMS** | greenfield — proves the chart on something we build |
| 5 | **opshub** | dev idles to zero, prod never launched |
| 6 | **rova** | last — the only product earning money |

**qnsc-kb dev is the first workload, and it replaced Flagsmith.** An earlier version put a
self-hosted Flagsmith here — real, off-the-shelf, no code to write. §4c removed it as a workload
entirely, so the slot needed refilling.

qnsc-kb dev is the better choice anyway, for a reason the Flagsmith plan never had: **it exercises
the hard parts.** Flagsmith would have proven `http` + a database + tunnel + Gateway + ESO. qnsc-kb
dev proves all of that plus PgBouncer, the migrator role (§5d), the `worker` kind, KEDA queue
scaling, a 1.5 GB model load needing a `startupProbe` (§9j), and the clamav split that unblocks
Graviton (§4c).

And the risk is genuinely low despite the ambition: **qnsc-kb production has no state file**, so
only dev migrates at step 2. Nothing anyone depends on is at stake, and a failure there is a
Tuesday rather than an incident.

Each step runs both platforms, cuts over at the Cloudflare Tunnel hostname, and keeps the ECS
stack until the new one is verified. **Do not migrate the three live products while building the
four new ones**; that is the one sequencing mistake that would make this fail.

### Three things this plan depends on that are not platform work

Each has an owner outside this document and a point at which it blocks. Named here because neither
appears in the table above, and both are currently unscheduled.

*(A third, monorepo tooling, was removed when §14 deferred the monorepo. Nothing in this migration
depends on repository layout.)*

#### Data residency, before step 1 creates anything

The account operates in **ap-southeast-1 (Singapore)**. QNSC is a Vietnamese company, and the LMS
will hold Vietnamese students' personal data. `VLSI-ACADEMY-LMS-PLAN.md` v0.2 already raised "the
absence of an AWS region in Vietnam" as an open item.

Two Vietnamese instruments bear on this, and both are legal determinations rather than
infrastructure ones:

* **Decree 13/2023 (PDPD)** — cross-border transfer of Vietnamese personal data carries a
  transfer-impact-assessment filing obligation. A filing requirement, not a prohibition.
* **Decree 53/2022** — data localisation for specified services and enterprises.

The infrastructure consequence is binary and expensive. **AWS has no Vietnam region**, so if
localisation applies, compliance means a domestic provider or on-premises — a different
architecture, not a region flag.

```
lower risk    rova · opshub — B2B internal tools
highest risk  LMS — student personal data at scale, and the newest product
```

**Get the determination before step 1.** Region is the single most expensive property to change
after the fact, and the answer is obtainable now. "Singapore is probably fine" is not a plan when a
lawyer can convert it into one.

`data-residency-question.md` in this directory is the brief to send. It states the facts, asks four
questions, and prices the three possible answers — the point being that answer A costs nothing,
answer B is expensive after the LMS is built and cheap before it, and answer C must not arrive
after the migration.

#### Open — what happens to `ci/scripts/stack_conformance.py`

It encodes ECS assumptions and carries the exception this design deletes:
`"api::cpu_architecture": "qnsc-kb is x86 — clamav/clamav ships no arm64 tag"`. §4c removes that
exception and §17 migrates everything off ECS, so the script is either ported, replaced by §11c's
golden-render CI, or retired. **Replaced is the right answer** — a rendered-manifest diff checks
more than a conformance script can, and maintaining both means two places to encode the same rule.
Decide it at step 1 rather than discovering it at step 4.

#### Incident response, decided rather than discovered

Three engineers cannot run a 24/7 rotation, and a policy that implies otherwise produces pages
nobody answers. So write down that this is not a 24/7 operation:

```
P1   rova production, revenue-affecting    page at any hour · two people · weekly rotation
P2   any other product, or degraded        next business day
P3   everything else                       backlog
```

**The SLO numbers in §9e must match that policy, or one of them is a lie.** 99.5% is 3.65 hours of
error budget per month, which a single overnight outage exhausts. 99.0% is 7.3 hours, which
survives a night.

```
rova prod           99.5%    → P1, because someone will get up for it
every other product 99.0%    → P2, because nobody will, and that is a decision
```

An SLO nobody will get out of bed for is not an SLO. Burn-rate alerts then route by tier, and only
rova's reach a phone.

Tooling stays proportionate: Grafana IRM if the Cloud plan carries it, otherwise Slack for P2 and
one escalation number for P1. PagerDuty for three people is buying process, not capability.

### The data does not move

Worth stating plainly, because "migrate the platform" sounds more dangerous than this is:

```
RDS            stays exactly where it is      no dump, no restore, no downtime
ElastiCache    stays                          same endpoint
Cloudflare R2  stays                          same buckets, same credentials
Secrets Manager stays                         ESO reads the same secrets ECS injected
```

**Only compute moves.** A cutover is: run the pods in the new cluster against the same database,
verify, then repoint the Cloudflare Tunnel hostname. Roll back by repointing it again — the ECS
service is still running and still connected to the same data.

**That is true about bytes and misleading about state — see §17b.** The Terraform state that owns
those databases is the same state that owns the ECS services, so removing the old platform by
destroying its stack removes the data with it. §17b is the sequence that avoids it.

Contrast with 2026-09-14, when rova-prod's database genuinely was destroyed and restored to
change a subnet group name: twelve minutes of downtime and four snapshots for insurance. Nothing
in this migration requires that. The database is the part that stays still.

## 17b. Running parallel, and retiring the old platform

The strategy is to build the new platform alongside the existing one, touching nothing, and to
remove the old estate only after the new one has been watched and tested. That is the right shape
and §17 already assumes it. This section is the part §17 leaves out: **how the old platform is
actually taken apart without destroying the thing it shares with the new one.**

### The trap: one Terraform state owns both the data and the compute

`rova/infra/modules/stack/main.tf` contains both halves:

```
line  225   module "secrets"
line  271   module "rds"            ← the production database
line  304   module "cache"
line 1567   module "ecs_cluster"    ← the thing to be removed
line 1704   module "ecs-service"
```

§17 says *"the data does not move"*. That is true about bytes and **misleading about state**. The
database file never moves, but the state that owns it is the same state that owns the ECS services
— so `tofu destroy` on the old stack, run to remove ECS, takes the database with it.

This estate has already paid for that lesson once. §17 records 2026-09-14: rova-prod's database
destroyed and restored to change a subnet group name — twelve minutes of downtime and four
snapshots taken for insurance.

### Insurance first, today, ahead of everything else

```hcl
lifecycle {
  prevent_destroy = true
}
```

On every `aws_db_instance`, `aws_elasticache_*` and `aws_secretsmanager_secret` in the live stacks.
It costs nothing, it converts an accidental destroy from an outage into a failed plan, and it
should have been there since September.

### Shrink the old stack. Do not destroy it.

Two routes reach "ECS gone, data intact", and one is far safer.

| | what it does | risk |
|---|---|---|
| **A — state surgery** | remove data resources from the old state, import into §6's `product-profile` | clean end state, and the single most dangerous operation in the migration |
| **B — shrink the stack** | delete only the ECS blocks from the old stack's *configuration* | nothing destroyed, nothing imported, no state edited |

**Take B.** The end state is data owned by the old module and compute owned by Kubernetes, which is
less tidy than §6 imagines — and §7's rule, *"if it outlives a deploy, OpenTofu owns it"*, is
satisfied either way. Tidiness is not worth being one typo from a production database. Route A
remains available for a calm quarter, or never.

### The sequence

```
1  prevent_destroy on every data resource                    today
2  build the new platform alongside                          nothing shared, nothing touched
3  run new pods against the SAME database                    both platforms live
4  cut over the Cloudflare Tunnel hostname                   rollback = point it back
5  soak and verify                                           see below
6  scale the ECS service to zero                             still there, still reversible
7  delete the ECS blocks from the stack configuration        data untouched
8  delete modules, workflows and dead code                   last
```

**Steps 6 and 7 are deliberately separate.** Scaling to zero is free and instantly reversible;
deleting configuration is neither. Nothing is deleted while it could still be needed in a hurry.

### Cut over one product at a time, not all at once

The parallel *build* is right. The parallel *cutover* is not, and the reason is feedback rather than
caution: **the chart design is unproven until something real runs on it.** If the eight axes of §4b
are wrong in a way nobody anticipated, that should surface on qnsc-kb *dev* in week three, not
across fifteen services in week fourteen.

§17's order stands: `qnsc-kb dev → qnsc-kb prod → LMS → opshub → rova`.

### What "all good" means, stated so it can be checked

"Monitor and test, and if it is fine we clean up" needs a definition, or the answer is always
"probably fine".

```
error rate        at or below the ECS baseline for the same window
p99 latency       within the tunnel's 5-15 ms overhead (§9j) of the ECS baseline
restarts          no unexplained pod restarts
SLO burn rate     flat (§9e)
cron coverage     every scheduled job has run at least once on the new platform —
                  including the slow ones. qnsc-kb's beat is every 5 minutes;
                  anything monthly needs either a month or a manual trigger
deploy            at least one release shipped through the new path end to end
rollback          at least one rollback rehearsed, not assumed (§13)
```

Soak durations, which differ by what an outage costs:

```
LMS · ai-dev-kit · solodesk                 3 days
qnsc-kb · opshub                            1 week
rova                                        2 weeks — the only product earning money
```

### The abort criterion, agreed before anyone is invested

A migration with no stopping rule becomes a sunk-cost march. Written now, while nothing has been
spent:

```
stop and re-evaluate if    step 1 exceeds 10 weeks
                           any product migration exceeds 2x its estimate
                           two consecutive products fail their soak
```

Stopping is not failure. It means something in the design was wrong, and the cost of finding out is
capped.

### Where it is safe to stop and stay stopped

If a product deadline lands mid-migration, these are not equivalent places to pause:

```
after step 1    two clusters running nothing. $146/month for zero delivered value.
                The WORST place to stop
after step 2    qnsc-kb dev on Kubernetes, everything else on ECS. Two platforms,
                tolerable, not free
after step 4    qnsc-kb migrated — the largest workload off ECS, and the chart proven
                against the hardest product. A GOOD place to stop indefinitely
```

Knowing that step 4 is the safe harbour should shape how a squeezed quarter is sequenced.

### The cleanup inventory, with a definition of done

"We will clean up afterwards" is the plan that gets deferred forever. §12c decommissions a
*product*; this decommissions a *platform*.

```
DELETE    ECS clusters, services, task definitions · CloudWatch log groups
          tf-modules: ecs-cluster · ecs-service · product-service · firelens-agent
                      observability-agent · tunnel-agent · oneshot-task · alb · alb-logs
          per-product infra/ directories · infra-template
          ci/scripts/stack_conformance.py (§17 — replaced, not ported)
          ECS deploy workflows

KEEP      RDS · ElastiCache · Cloudflare R2 · Secrets Manager · VPC · fck-nat
          DNS · ECR
          docker-compose files — §11b keeps them as the local development story
```

**Done means:** no ECS service exists in either account, no `tf-modules` module in the DELETE list
has a caller, `tofu plan` is clean on every remaining stack, and the §12 cost dashboard shows no
ECS line for a full month.

Give it a date and an owner at the moment rova finishes its soak. A cleanup with neither is a
platform you keep paying for and nobody maintains.

## 18. Readiness: what must be true before step 1

**The executable form of this section is `implementation-plan.md` in this directory.** It breaks
§17, §17b and this section into numbered tasks with owners, dependencies and acceptance tests, and
it is the artefact to hand to whoever does the work. This section remains the argument for why the
work is shaped that way.


This document describes a design. This section describes whether it can be started, which is a
different question and the one to answer first.

### Blocking — step 1 cannot begin

```
data residency        `data-residency-question.md` is written and NOT SENT. Answer C
                      means a different cloud provider, not a different region, and it
                      must not arrive after clusters exist
cost allocation tags  §12. There is no way to buy this back — a tag applied next year
                      says nothing about this year, and §12b depends entirely on it
§15d measurement      two weeks of CloudWatch. Gates node sizing, the Auto Mode trade
                      (§14) and whether §15's numbers mean anything
```

All three are cheap. None is started. The first two have lead time that cannot be compressed.

### Decisions waiting on a person, not on work

```
on-call               who carries a phone for rova, or nobody does (§17)
LMS deployment target VLSI-ACADEMY-LMS-PLAN says "the ECS deploy path"; §17 says
                      Kubernetes, step 3. Two current documents disagree
stack_conformance.py  ported, replaced by §11c's golden render, or retired (§17)
ArgoCD bootstrap      who installs the installer (§13)
```

### Written but not applied

```
ECR retention         tf-modules/modules/ecr switched to release_retention_days.
                      Needs `aws ecr start-lifecycle-policy-preview` and its own PR
:latest removal       stop publishing it from CI, THEN flip image_tag_mutability to
                      IMMUTABLE in all four repositories (§11). Order matters
```

### Claims this document makes that are not yet true

Stated plainly, because §13 says an untested recovery claim is decoration and the same standard
applies to the rest:

```
"the cluster is reproducible from git"   untested. §13's rehearsal has not run
RTO / RPO table                          estimates until it does
§15's prices                             list prices from memory, September 2026.
                                         Verify against the AWS calculator
§15's requests                           ECS ALLOCATIONS, not measurements (§15d)
```

### The timeline, corrected

§17 carried **"6–10 weeks for the platform plus five migrations"** from the first draft. That
estimate predates roughly two thirds of this document. Since it was written the platform gained:

```
KEDA · VPA · PgBouncer and a second database role · two-tier Alloy · six observability
signals · SLO rendering · dashboards per kind · ValidatingAdmissionPolicy ·
policy-controller · chart OCI publishing, pinning and golden-render CI · EKS access
entries, RBAC, audit logs and break-glass · the platform namespace · EventBridge and
its three controls · decommissioning
```

**Realistically 12–16 weeks at the current scope — or stage it, which is the better answer.**

### Staged scope: what genuinely belongs in step 1

Not everything here has to exist before the first product ships. Three signals is a working
observability stack; six is the destination.

```
STEP 1    EKS ×2 · ArgoCD · ESO · KEDA · Alloy two-tier with metrics, logs and traces
          PSA + ValidatingAdmissionPolicy · shared Postgres + PgBouncer + migrator role
          EKS access entries and audit logs · chart with CI, OCI publishing and pinning
          S3 gateway endpoint · subnet resize · cost allocation tags
AFTER THE FIRST PRODUCT SHIPS
          profiles · RUM · synthetics · SLO rendering · dashboards per kind · OpenCost
          VPA · policy-controller signatures · EventBridge · Argo Rollouts · previews
```

Step 1 staged this way is roughly **6–8 weeks**, which is the number the original estimate was
probably reaching for.

### The honest summary

The design is settled — there are no open forks left in it. It is **not ready to start**, and the
three blocking items are all cheap, all unstarted, and two of them have lead time that cannot be
recovered.

The case for the platform is also thinner than the first draft made: the IC lab driver was
withdrawn (§"The decision"), and cost re-priced to a wash against Fargate (§15). What remains is
one chart across fifteen services, product shapes that will keep differing, and a preview
environment per pull request. That is sufficient at this size, and it is stated this plainly so
that a reader can weigh it rather than inherit it.

