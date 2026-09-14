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
ONE account (608983206583) to start
  ├── EKS cluster "dev"   in runtime-dev VPC   10.90.0.0/16
  └── EKS cluster "prod"  in runtime-prod VPC  10.91.0.0/16
namespace per product              rova · opshub · kb · lms …
separate cluster for the IC lab    see §10
```

**Separate clusters for dev and prod is not negotiable. Separate AWS accounts is deferred.**

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
| `system` | on-demand, 2 small | CoreDNS, ArgoCD, Alloy, External Secrets |
| `general` | **Spot** | all application workloads |
| `lab` | Spot, large, tainted, scales to zero | IC lab sessions |

**Fargate profiles are excluded, not overlooked.** Fargate for EKS does not support DaemonSets,
which eliminates Alloy — and Alloy is one of the main reasons to do this at all (§8).

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

Before each upgrade, check API compatibility for the four things that pin Kubernetes versions:
**ArgoCD, Alloy, External Secrets Operator, Kyverno.** A removed API in a controller is the
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

Set an explicit timeout — 600s — because the default will kill a slow migration part-way, which
is the worst possible moment. Recovery is already covered by the expand-and-contract rule (§13):
a half-applied migration leaves a forward-compatible schema, so re-running the sync is safe.
Stating that here because "the migration died halfway through" is otherwise a panic rather than a
retry.

## 4b. Any architecture, expressed as a composition

Size presets answer *how big*. They do not answer *what shape*, and the products will not agree
on shape: rova and opshub are modular monoliths, the AI dev kit is one service, Flagsmith is a
container nobody here wrote, and the IC lab is per-user compute. A platform that assumes one
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
| `stateful` | StatefulSet + PersistentVolumeClaim |
| `session` | ephemeral Pod per user + ResourceQuota |

### Axis 2 — exposure

```yaml
expose: public      # tunnel route, reachable from the internet (WAF, rate limit in front)
expose: protected   # tunnel route + Cloudflare Access — reachable anywhere, by our people only
expose: internal    # ClusterIP only, service-to-service inside the cluster
expose: none        # no Service at all (workers, jobs)
```

`protected` is the state most of this estate needs and the one most easily got wrong. opshub is
an internal operations tool, the Flagsmith admin UI is internal, and the AI dev kit is for the
team — none should be on the public internet with only a WAF in front, and none should be
`internal` either, because people need them from a laptop.

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

Third-party containers are ordinary services. Flagsmith needs no repository and no bespoke
handling — it is a values file with an upstream image.

### The compositions

| architecture | expressed as |
|---|---|
| single service | one `http` |
| modular monolith | `http` + `worker` + `job` |
| microservices | N `http`, one `public`, rest `internal` |
| event-driven | one `worker` per consumer + `queue.sqs` in the profile |
| batch / ETL | `cron` services |
| model serving | `http` with `resources.gpu` |
| per-user compute | `session` + a tainted node pool |
| third-party app | `http` with an upstream image |
| needs local disk | `stateful` |

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

## 5b. Environment differences

Values are per product **per environment** — `base.yaml` plus `dev.yaml` or `prod.yaml`, rendered
by ArgoCD against one chart. This is strictly better than today, where the dev/prod difference is
spread across two separate OpenTofu stacks and drifts silently; here it is two override files
against one definition.

| | dev | prod |
|---|---|---|
| HPA | **off** — fixed 1 replica | on, 2–6 |
| PodDisruptionBudget | **off** | on |
| node capacity | Spot only | Spot with on-demand fallback |
| anti-affinity | none | spread across AZs |
| resource requests | low | realistic |
| Multi-AZ database | no | opt-in at size L |
| log retention | 7 days | 30–90 days |

Turning HPA and PDB **off** in dev matters more than it appears. With no disruption budget,
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

**A `SecretStore` per namespace, each with its own service account and IRSA role** — not one
`ClusterSecretStore`. Cluster-wide is less setup and means a single compromised namespace can read
every product's secrets. Per-namespace keeps the blast radius equal to the namespace, which is the
same principle as the NetworkPolicies in §10.

This fixes a measured failure. On 2026-09-06 the Grafana OTLP credential was rotated and the
`observability-token` field was updated in **four separate secrets**, one per product per
environment. The value was wrong — built from the org id rather than the stack id — and rova and
opshub shipped no metrics or traces for **seven days**. With Alloy there is **one** credential in
one place.

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

```
Alloy DaemonSet (one per cluster) → Grafana Cloud
```

This replaces four sidecar modules per service — `otel_agent_api`, `otel_agent_worker`,
`firelens_agent_api`, `firelens_agent_worker` — because ECS has no node-level agent and every
task needs its own collectors. One DaemonSet per cluster instead.

**Assume the free tier is exceeded, and allowlist accordingly.** Kubernetes telemetry is
series-heavy in a way ECS is not: kube-state-metrics, cAdvisor per container and node-exporter per
node, all with high-cardinality labels. Fifteen services across two clusters will plausibly pass
Grafana Cloud's 10k-series free tier, and the current 0.19 GB of log storage is not a measurement
that survives the move.

So Alloy carries a `metric_relabel` allowlist from day one — keep what a dashboard or an alert
reads, drop the rest — and §15 budgets ~$50/month rather than assuming free. Check the series
count after the first cluster is running, not after the first invoice.

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

Kubernetes makes the last one **stronger** than it is today: Kyverno can require signed images
cluster-wide, so an unsigned image cannot run even if a pipeline is bypassed. That is a policy
boundary rather than a CI step, and it is worth the swap.

Images are immutable and tagged by commit — never `:latest`, enforced by Kyverno (§10).

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

### That claim must be rehearsed, not asserted

"The cluster is reproducible from git" is the same *class* of statement as "alarms are
configured" — which was true of this account for weeks while every alarm topic had zero
subscribers. An untested recovery claim is decoration.

So: **delete the dev cluster and rebuild it from git. Time it. Write the number in this
document.** Repeat annually or after any change to the bootstrap path.

The rehearsal is also the only way to find what is *not* in git:

```
PersistentVolumeClaims    stateful services — needs Velero or an explicit "no PVCs" rule
ArgoCD's own bootstrap    the chicken-and-egg: who installs the installer
Secrets                   values live in Secrets Manager, correctly — but ESO must be
                          installed and its IRSA role must exist before anything syncs
cluster-scoped resources  CRDs, Kyverno policies, StorageClasses
```

Until that rehearsal happens, the RTO figures above are estimates. Mark them as such.

**Expand and contract.** A release may add columns or tables. Dropping or renaming happens in a
*later* release, after the previous version is fully retired. Never both in one deploy — a
rollback after a destructive migration is unrecoverable, and rollback is the main thing GitOps
promises.

## 14. Two decisions, and their reasoning

Both were left open in the first draft and are now settled. Recorded with reasoning rather than
as bare choices, because the reasoning is what a future reader needs in order to disagree
usefully.

### Monorepo for what we own, with two deliberate exceptions

```
MONOREPO   rova · opshub · ai-dev-kit · app-platform · lms (if TypeScript)
SEPARATE   solodesk              — mobile toolchain
SEPARATE   qnsc-kb-backend       — ownership
SEPARATE   qnsc-kb-frontend      — ownership
SEPARATE   infra · tf-modules · delivery · ci · docs
```

The argument is measured, not stylistic. On 2026-09-13 `sanitizeString` was extracted into
`app-platform`, and rova and opshub could not use it until `platform-http` was **published** —
so both kept their duplicated copy, which is still there. Four steps, three pull requests, and a
window in which the three repositories disagreed. In a monorepo that is one commit.

That publish-then-consume tax is the polyrepo cost, and it is paid on every shared change. With
two or three engineers who all touch everything, there are no team boundaries for repository
boundaries to align with, so the tax buys nothing.

**Mobile stays out, and this is not arbitrary.** solodesk needs Xcode and Gradle, Fastlane, code
signing, and macOS CI runners. None of that shares tooling, caching, or a dependency graph with
the backend products — a monorepo would gain atomicity it has no use for and inherit CI it cannot
run.

**LMS is conditional.** If it is TypeScript it joins the monorepo. If its stack is something else
it stays separate for the same reason as mobile. Decide when the stack is chosen, not now.

Requires Nx or Turborepo for affected-only CI. Without task-graph awareness a monorepo tests
everything on every commit and the productivity gain inverts.

### EKS Auto Mode

AWS manages nodes, AMIs, patching and upgrades, at roughly a **12% premium** on node cost — about
**$12/month** on ~$100 of nodes.

That is the cheapest thing in this document. Two or three engineers should not be rotating AMIs
or sequencing node upgrades, and this is exactly the class of work that gets deferred until it
becomes an incident. Karpenter's advantage is control over instance families, which nothing here
needs.

**Revisit when the IC lab arrives.** GPU or high-core instance families for EDA workloads may
need instance types or AMI customisation Auto Mode does not expose. Verify against Auto Mode's
supported families at that point; if it does not fit, Karpenter on EC2 for the lab cluster only.
The workloads are unchanged either way — only the provisioner differs.

### Both are reversible

Monorepo → polyrepo is a repository split. Auto Mode → Karpenter is swapping a node provisioner
and leaves every manifest untouched. Neither is a one-way door, which is why they were worth
deciding rather than deliberating.

## 15. Cost, honestly

August 2026, measured, three products across two environments:

```
 37.35  RDS          31.23  ECR            24.30  ECS Fargate
 24.23  ElastiCache   6.19  Tax             6.10  EC2 (fck-nat)
  6.04  VPC           3.39  Secrets         2.91  CloudWatch      2.01  KMS
────────
150.56  TOTAL
```

### The first model was wrong, and wrong in the interesting direction

An earlier version of this section scaled three products' bill up to seven and concluded
Kubernetes cost $190–290/month more. That method was invalid: **Fargate bills per task and does
not bin-pack**, so its compute line grows linearly with services rather than staying near $80.

Recomputed from resource requests instead:

```
prod ≈ 16 vCPU / 40 GiB      qnsc-kb alone is 8 vCPU / 24 GiB after 2026-09-14
dev  ≈ 10 vCPU / 24 GiB      qnsc-kb dominates here too — the e5 model needs the memory
```

| | ECS Fargate | EKS + Auto Mode |
|---|---|---|
| prod compute | $603 — 16 × $0.04048 + 40 × $0.004445, ×730h | $200 — Spot-heavy, on-demand fallback for `http` |
| dev compute | $112 — Fargate Spot | $70 — Spot |
| control planes | $0 | $146 — two clusters |
| Auto Mode premium | — | $32 — ~12% of nodes |
| EBS | — | $10 |
| unchanged AWS¹ | $192 | $192 |
| Grafana Cloud | free tier | $50 — see §9 |
| tax ~8% | $72 | $56 |
| **total** | **~$980** | **~$756** |

¹ RDS $125 · ElastiCache $32 · ECR $8 · VPC $12 · Secrets $6 · CloudWatch $6 · KMS $3 —
identical either way.

**Kubernetes comes out roughly $220/month cheaper at seven products.** The reason is structural,
not a modelling artefact: Fargate charges a per-vCPU premium per task with no packing, while EKS
pays a $146 floor and then bin-packs fifteen services onto a handful of nodes.

The crossover is around **10–12 always-on services**. At six, which is today, Fargate is
correctly cheaper — which is why this is the right decision now and would have been the wrong one
six months ago.

**Where this could be wrong.** These are list prices, and the per-service requests are estimates
rather than measurements. qnsc-kb is roughly half of both environments, so the real figure depends
on qnsc-kb's actual requests more than on anything else in the table. Measure before committing
to node sizes.

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
| 1 | Subnet resize · EKS ×2 · ArgoCD · Alloy · ESO · policy baseline | foundation — no external dependency |
| 2 | **LMS** | greenfield — proves the chart with nothing at risk |
| 3 | **qnsc-kb** | prod has no state file; only dev migrates |
| 4 | **opshub** | dev idles to zero, prod never launched |
| 5 | **rova** | last — the only product earning money |
| 6 | IC lab cluster | after the chart is proven |

Each step runs both platforms, cuts over at the Cloudflare Tunnel hostname, and keeps the ECS
stack until the new one is verified. **Do not migrate the three live products while building the
four new ones**; that is the one sequencing mistake that would make this fail.

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

Contrast with 2026-09-14, when rova-prod's database genuinely was destroyed and restored to
change a subnet group name: twelve minutes of downtime and four snapshots for insurance. Nothing
in this migration requires that. The database is the part that stays still.
