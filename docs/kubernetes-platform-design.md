# Platform design for seven products: EKS, ArgoCD, and one chart

Status: **proposed, nothing provisioned.** Written 2026-09-14. Supersedes the compute half of
`product-service-extraction.md`; the reasoning in that document about *why* duplication is the
core problem still holds and is the reason this one exists.

## The decision

Move all products onto Kubernetes (EKS), delivered by ArgoCD, with **one Helm library chart**
and **one OpenTofu profile module** shared by every product. Keep OpenTofu for cloud
resources, Cloudflare for edge and object storage, Grafana Cloud for telemetry.

Three facts drive it, and only three:

1. **Seven products, ~15 services.** rova 3, opshub 3, kb 3, LMS 2–3, solodesk 2, AI dev kit 1,
   Flagsmith 1. That was premature at three products. It is not premature at fifteen services.
2. **The IC lab needs per-user ephemeral compute.** Spawning a sandboxed EDA environment per
   student, with quotas and a session lifecycle, is a scheduling problem. ECS has no answer;
   Kubernetes was built for it.
3. **Products differ in size and shape and will keep differing.** A platform that assumes one
   product shape will be worked around. This design makes size a value, not a fork.

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
true, and it is outweighed by the three facts above. It is recorded here so the decision is not
re-argued from scratch in six months.

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
PLATFORM (4)   infra · tf-modules · delivery · ci
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

`delivery` is new and load-bearing: the Helm library chart plus the ArgoCD app-of-apps. It is
the single source of deployment truth.

Flagsmith needs no repository — it is off-the-shelf, so it is a values file in `delivery`.

Retire or fold in: `solo-desk-mockup`, `Logo_QNSC_v31`, `mcp-tools`, `qnsc-landing`,
`ceo-suite`, `tactile-ledger-flow`, `vlsi_deep_training`.

**Open decision — monorepo instead.** For two or three engineers who all touch everything,
polyrepo boundaries have no team boundaries to align with, and the cost is real: on 2026-09-13,
`sanitizeString` could not be shared until `platform-http` was published, so products kept a
duplicate copy. A monorepo makes that one commit. Roughly 60/40 in favour of the monorepo. See
§14.

## 2. Accounts and clusters

```
AWS account per environment       dev · prod                (request from TrueIDC)
one EKS cluster per account
namespace per product             rova · opshub · kb · lms …
separate cluster for the IC lab   see §10
```

Separate accounts per environment is the 2026 baseline for blast radius and what an auditor
expects. QNSC is a member account in TrueIDC's organisation, so this is a request rather than a
decision — make it early, because retrofitting account boundaries is expensive.

Node pools, via Karpenter or EKS Auto Mode:

| pool | capacity | purpose |
|---|---|---|
| `system` | on-demand, 2 small | CoreDNS, ArgoCD, Alloy, External Secrets |
| `general` | **Spot** | all application workloads |
| `lab` | Spot, large, tainted, scales to zero | IC lab sessions |

**Fargate profiles are excluded, not overlooked.** Fargate for EKS does not support DaemonSets,
which eliminates Alloy — and Alloy is one of the main reasons to do this at all (§8).

**Open decision — Auto Mode or Karpenter on EC2.** Auto Mode has AWS manage nodes, add-ons and
upgrades at a per-pod premium; Karpenter gives control at the cost of owning it. See §14.

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

### No ingress controller, and that is a strength

Cloudflare Tunnel dials **outward**, so there is no inbound path to secure:

```
internet → Cloudflare edge (WAF, rate limit, TLS, Turnstile)
         → tunnel → cloudflared Deployment → Service → pod
```

Not needed: ALB/NLB (~$16/month each), AWS Load Balancer Controller, Ingress resources,
cert-manager. There is no public IP and nothing to scan. This is the best decision in the
current architecture and it carries over unchanged.

`cloudflared` runs with **≥2 replicas per product** — Cloudflare load-balances across
connectors, and one replica is a single point of failure for that product's ingress.

Add **Gateway API** only when adopting canary deploys (§11). Never `Ingress`, which is frozen.
Never an ALB behind a tunnel — that pays for a load balancer the tunnel bypasses.

## 4. The Helm library chart: service kinds

The chart knows what a *service* is. A product declares as many as it needs, so a monolith is
three services and a product that later splits into eight is still the same chart.

| kind | renders |
|---|---|
| `http` | Deployment, Service, HPA, PDB, tunnel route |
| `worker` | Deployment, HPA — no Service, no ingress |
| `job` | Job as an **ArgoCD PreSync hook** |
| `cron` | CronJob |
| `session` | ephemeral Pod per user + ResourceQuota (IC lab) |

Migrations are a `job` running as `argocd.argoproj.io/hook: PreSync`, **not** a Helm
`pre-upgrade` hook. With ArgoCD owning the lifecycle, Helm hook failure semantics and ArgoCD's
sync state disagree, producing releases that are "failed" in Helm and "Synced" in ArgoCD.
PreSync blocks the sync on migration failure, which is the desired behaviour.

## 5. Size presets

Products pick a preset and override individual fields. The preset exists so a new product starts
sane, not so it stays boxed in.

| | XS | S | M | L |
|---|---|---|---|---|
| replica floor | 1 | 1 | 1 dev / 2 prod | 2 dev / 3 prod |
| PodDisruptionBudget | no | no | yes | yes |
| own Postgres | no — shared | optional | yes | yes, + replica option |
| cache | no | no | shared dev / dedicated prod | dedicated |
| Multi-AZ prod | no | no | no | opt-in |
| node pool | general | general | general | prod on-demand |
| examples | ai-dev-kit, Flagsmith | solodesk | opshub, kb, LMS | rova |

```yaml
# kb — size M
size: m
services:
  api:      { kind: http, port: 8000 }
  worker:   { kind: worker }
  beat:     { kind: cron, schedule: "*/5 * * * *" }
  migrator: { kind: job }
data:
  postgres: { mode: dedicated, extensions: [vector, pgcrypto], engine_version: "16" }
  cache:    { dev: shared, prod: dedicated }
  objectStorage: r2
```

**The rule that makes this hold:** presets live in the chart and the module, never copied into
product repositories. The moment a product hand-writes a Deployment because the preset did not
fit, there are seven copies again. If a preset does not fit, the preset gains a field.

## 6. The `product-profile` OpenTofu module

Cloud resources need the same capability flags, or the flexibility stops at the cluster edge.

```hcl
module "product" {
  source  = "…/modules/product-profile?ref=product-profile-v1.0.0"
  product = "kb"
  env     = "prod"
  size    = "m"

  postgres = { mode = "dedicated", extensions = ["vector"], engine_version = "16" }
  cache    = { mode = "dedicated" }
  storage  = { r2_buckets = ["sources", "attachments"] }
  queue    = { sqs = false }
}
```

`mode = "shared"` provisions a database and role on the platform Postgres; `mode = "dedicated"`
provisions an RDS instance. The interface is identical either way, so a product graduates from
shared to dedicated by changing a value — which is the "adapt as it grows" property, expressed
where it has to be expressed.

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

## 8. Secrets

```
Secrets Manager → External Secrets Operator → Kubernetes Secret → pod env
```

OpenTofu creates the containers; values are written out of band and never enter state or git.
ESO reads via IRSA.

This fixes a measured failure. On 2026-09-06 the Grafana OTLP credential was rotated and the
`observability-token` field was updated in **four separate secrets**, one per product per
environment. The value was wrong — built from the org id rather than the stack id — and rova and
opshub shipped no metrics or traces for **seven days**. With Alloy there is **one** credential in
one place.

## 9. Observability

```
Alloy DaemonSet (one per cluster) → Grafana Cloud
```

This replaces four sidecar modules per service — `otel_agent_api`, `otel_agent_worker`,
`firelens_agent_api`, `firelens_agent_worker` — because ECS has no node-level agent and every
task needs its own collectors. One DaemonSet per cluster instead.

**Do not self-host LGTM.** Total CloudWatch log storage today is 0.19 GB and Grafana Cloud usage
is within the free tier. Self-hosting means running Mimir or Thanos, Loki, and Tempo — four
stateful distributed systems, plausibly more operational work than the application platform.
`ARCHITECTURE_FUTURE_SCALE.md` gates this correctly on "managed bill grows / need residency /
high volume". None is true.

## 10. Policy baseline and lab isolation

Namespaces are not isolation. Without this, seven products in one cluster share a fate.

```
Pod Security Standards   restricted, enforced per namespace
NetworkPolicy            default-deny, then allow explicitly
ResourceQuota            per namespace — one product cannot starve others
LimitRange               default requests/limits; nothing runs unbounded
Kyverno                  no :latest · no privileged · limits required · signed images only
```

`security-baseline` already provides SOC 2 *detective* controls. This is the preventive half.

**The IC lab is a security boundary, not a namespace.** Students run arbitrary code, and an
ordinary container is not a boundary against hostile code — an escape reaches the node, and the
node reaches other tenants.

```
its own CLUSTER, not a namespace
gVisor or Kata Containers for session pods
no host mounts · no service-account token · egress locked to the license server
ResourceQuota per session · hard timeouts
```

The extra control-plane cost is the cheapest part of that decision.

## 11. Delivery

```
PR              tests · build · push to ECR with an immutable tag
merge to main   CI bumps the dev tag in `delivery` → ArgoCD syncs dev
promote         PR in `delivery` changing the prod tag → approval → ArgoCD syncs prod
rollback        revert that commit
```

Promotion becomes **a reviewable diff**. Today it is a version tag that applies whatever `main`
contains, which is why rova production ran code from before 7 September while `main` was 44
commits ahead — and why an alerting fix could not reach production without shipping nine
features.

Canary via **Argo Rollouts + Gateway API**, when wanted. Optional per product (`delivery.canary`).

### Preview environments

```
ApplicationSet with a PR generator
  → every PR gets a namespace, a deployed stack, a URL
  → torn down on merge or close
  → per-PR database on the shared dev Postgres
```

Nearly free on ArgoCD, genuinely hard on ECS. For a small team reviewing across seven products,
"click the link on the PR" is worth more than most of the rest of this document.

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

## 13. Recovery, and a migration rule

State the promise rather than implying it from snapshot settings:

| size | RPO | RTO | mechanism |
|---|---|---|---|
| XS / S | 24h | 4h | daily snapshot, redeploy from git |
| M | 1h | 2h | PITR + redeploy |
| L (rova) | 5 min | 1h | PITR, Multi-AZ opt-in |

GitOps adds a property worth writing down: **the cluster is reproducible from git.** Losing one
becomes "recreate and let ArgoCD sync" — minutes, not a rebuild.

**Expand and contract.** A release may add columns or tables. Dropping or renaming happens in a
*later* release, after the previous version is fully retired. Never both in one deploy — a
rollback after a destructive migration is unrecoverable, and rollback is the main thing GitOps
promises.

## 14. Open decisions

Two, deliberately left for a human:

1. **Monorepo or polyrepo.** Roughly 60/40 toward monorepo at this team size. Changes the CI
   design substantially, so decide before building `ci`.
2. **EKS Auto Mode or Karpenter on EC2.** Cost versus control.

## 15. Cost, honestly

August 2026, measured, three products across two environments:

```
 37.35  RDS          31.23  ECR            24.30  ECS Fargate
 24.23  ElastiCache   6.19  Tax             6.10  EC2 (fck-nat)
  6.04  VPC           3.39  Secrets         2.91  CloudWatch      2.01  KMS
────────
150.56  TOTAL
```

Modelled at seven products:

| | monthly |
|---|---|
| stay on ECS Fargate | ~$294 |
| EKS + ArgoCD | ~$480 |
| + Rancher | ~$586 |

**Roughly $190–290/month more**, narrowed by Karpenter scaling nodes down. RDS, ElastiCache,
ECR, VPC, Secrets and KMS are identical in both — the cluster is pure addition. Some scale-to-zero
is lost: the `system` pool must stay alive for CoreDNS, ArgoCD and Alloy.

Realistically **6–10 weeks** for the platform plus five migrations, alongside building four
products.

## 16. Deliberately excluded

* **Rancher** — manages *many clusters, in many places*. Two managed clusters in one account
  make it pure overhead. Revisit when the IC lab runs on owned hardware; that is its sweet spot
  and the natural moment to introduce it.
* **Service mesh** — fifteen services does not need an mTLS mesh.
* **Kafka** — SQS is sufficient; `ARCHITECTURE_FUTURE_SCALE.md` gates it at Stage 3.
* **Self-hosted LGTM** — see §9.
* **Crossplane** — see §7.
* **Multi-region** — no customer requirement yet.

## 17. Migration order

| # | step | why here |
|---|---|---|
| 1 | Accounts · subnet resize · EKS ×2 · ArgoCD · Alloy · ESO · policy baseline | foundation |
| 2 | **LMS** | greenfield — proves the chart with nothing at risk |
| 3 | **qnsc-kb** | prod has no state file; only dev migrates |
| 4 | **opshub** | dev idles to zero, prod never launched |
| 5 | **rova** | last — the only product earning money |
| 6 | IC lab cluster | after the chart is proven |

Each step runs both platforms, cuts over at the Cloudflare Tunnel hostname, and keeps the ECS
stack until the new one is verified. **Do not migrate the three live products while building the
four new ones**; that is the one sequencing mistake that would make this fail.
