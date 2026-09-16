# infra

> Platform-level AWS infrastructure shared across all QNSC products.

## What this repo manages

| Resource | Why it's here |
|---|---|
| GitHub OIDC provider | AWS allows only **one** per account — all products share it |
| S3 state bucket (`qnsc-tofu-state`) | Single source of truth for all Tofu state |
| DynamoDB lock table (`qnsc-tofu-locks`) | Prevents concurrent applies across all product repos |
| AWS Organizations + SCPs + Identity Center (`live/organization`) | Org root, OUs, baseline guardrails, SSO permission sets — the **identity foundation** (see that stack's README) |
| Security baseline (`live/security-baseline`) | CloudTrail + Config + GuardDuty + Access Analyzer — SOC 2 detective controls |
| Shared runtime (`live/runtime-dev`, `live/runtime-prod`) | One VPC + fck-nat egress + security groups per environment, shared by every product. Dev also holds one shared Valkey node. Neither runs an ALB today (`enable_alb = false`) — products ingress via Cloudflare Tunnel sidecars |
| Edge (`live/edge`) | Cloudflare zone governance for `qnsc.vn`: WAF, rate limiting, Turnstile, plus the wildcard ACM cert other stacks read |
| Observability (`live/observability`) | Grafana Cloud stack every product pushes telemetry to |
| EKS clusters (`live/cluster-dev`, `live/cluster-prod`) | Auto Mode clusters, IRSA trust and human access entries. ArgoCD is hub-and-spoke — one instance in prod managing both |
| Shared data tier (`live/data-dev`, `live/data-prod`) | The shared Postgres, the preview Postgres and the one Valkey per environment (§5d) |
| Product stacks (`live/<product>-<env>`) | Each product's database, roles, secrets, queues and IRSA roles, via one `product-profile` call. `live/kb-dev` is the first (§17 step 2) |
| Object storage (`live/storage-dev`, `live/storage-prod`) | Cloudflare R2 buckets (per-product attachments, public assets, KB sources, ceo-suite backups). Provisioned here so the R2 admin token stays in one stack instead of every product's CI. Pins Cloudflare provider v5 |

## What belongs in **product** infra repos — being retired

**This is the state today, not the target.** Each product repository still carries
`infra/live/{_shared,develop,prod}` and `infra/modules/stack`, holding its ECS
cluster, RDS, ElastiCache, SQS, ECR repositories and IAM deploy roles:

- `rova` — Rova product
- `opshub` — OpsHub product (internal IT/HR operations)
- `qnsc-kb-backend` — knowledge base (FastAPI + Celery)

That is 9,580 lines implementing one pattern three times, and it has drifted —
`cache.shared` existed in two of the three, so opshub-develop ran an ElastiCache
node at ~$15/month for services pinned at `min_count = 0`. §17b also records the
twelve minutes of downtime on 2026-09-14 spent learning what `tofu destroy` does
to a database when one state owns both the database and the ECS services.

§17 moves each product to `live/<product>-<env>` here, one at a time, through a
single `product-profile` call. A product's `infra/` is deleted only after its new
stack has applied and run.

**Read [`docs/repository-boundaries.md`](docs/repository-boundaries.md) before
adding infrastructure anywhere.** It states the rule for each repository boundary,
what each one enforces it with, and why `product-service` — the other
consolidation path — is superseded rather than next.

Shared **internal tooling** that is not a product also lives outside this repo, for the same
reason: it needs an application deploy pipeline (image, migrations, rollout verification),
not just a Tofu one. See `shared-services` (feature flags and future internal tenants).

## First-time bootstrap (one-time, run manually)

```bash
cd live/bootstrap

# 1. Init with local backend
tofu init

# 2. Apply — creates S3 bucket + DynamoDB + OIDC provider
tofu apply

# 3. Migrate state to the newly-created S3 bucket
#    Uncomment the s3 backend block in main.tf, then:
tofu init -migrate-state
```

After bootstrap, product infra repos can reference the OIDC ARN:

```hcl
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# Use in product iam-oidc modules:
oidc_provider_arn = data.terraform_remote_state.platform.outputs.oidc_provider_arn
```

## State key namespacing

```
qnsc-tofu-state/
  platform/bootstrap/terraform.tfstate     ← this repo (state backend, OIDC, KMS, artifacts)
  platform/organization/terraform.tfstate  ← this repo (Organizations, OUs, SCPs, Identity Center)
  platform/security-baseline/terraform.tfstate ← this repo (CloudTrail, Config, GuardDuty)
  platform/runtime-dev/terraform.tfstate   ← this repo (shared develop VPC + shared cache)
  platform/runtime-prod/terraform.tfstate  ← this repo (shared production VPC)
  platform/edge/terraform.tfstate          ← this repo (Cloudflare zone WAF/rate-limit + ACM cert)
  platform/observability/terraform.tfstate ← this repo (Grafana Cloud stack)
  platform/storage-dev/terraform.tfstate   ← this repo (R2 buckets, develop)
  platform/storage-prod/terraform.tfstate  ← this repo (R2 buckets, production)
  rova/shared/terraform.tfstate            ← rova _shared
  rova/develop/terraform.tfstate           ← rova develop
  rova/prod/terraform.tfstate              ← rova prod
  opshub/shared/terraform.tfstate          ← opshub _shared
  opshub/develop/terraform.tfstate         ← opshub develop
  opshub/prod/terraform.tfstate            ← opshub prod
  qnsc-kb/shared/terraform.tfstate         ← qnsc-kb-backend _shared
  qnsc-kb/develop/terraform.tfstate        ← qnsc-kb-backend develop
  qnsc-kb/prod/terraform.tfstate           ← qnsc-kb-backend prod
  shared-services/prod/terraform.tfstate   ← shared internal tooling (prod only)
```

Apply order matters in two places: `live/edge` creates the wildcard ACM cert that both
runtime stacks read, so it applies first; and `live/bootstrap` owns the state backend
itself, so it is the one stack bootstrapped manually (see above).

## Scheduled controls

Three jobs run unattended, each covering a failure class the other two cannot see. They
were added together on 2026-09-13 after an audit found problems in all three classes at
once, none of which any existing check reported.

| Workflow | Script | The question it answers |
|---|---|---|
| `drift-detection` | — (`tofu plan`) | State says X, does AWS still say X? |
| `unmanaged-resources` | `scripts/unmanaged_resources.py` | Does AWS hold cost-bearing things state has never known about? |
| `alerting-health` | `scripts/alerting_health.py` | Is the configuration intact but unable to deliver? |

The third is the one that hides longest, because it produces no diff. Every alarm topic in
this account once had zero subscriptions, the budget had no notifications, and six RDS
alarms sat in `INSUFFICIENT_DATA` for months against a dimension that never publishes.
`tofu plan` was clean throughout — correctly, since nothing had drifted. The configuration
said exactly what it was written to say, and what it said was "notify `[]`".

Each script exits non-zero on a finding, so a failed scheduled run *is* the notification —
a cron job has no PR to annotate, and GitHub already emails on failure. Both carry an
`ALLOWLIST` requiring a reason per entry, so suppressions cannot accumulate silently.

Note that `alerting-health` cannot fix what it finds: confirming an SNS email subscription
requires clicking the emailed link and has no API. Pending confirmations are therefore
reported as findings rather than repaired, and AWS deletes them after roughly 72 hours —
which is why that job runs daily rather than weekly.

## VPC allocation

`allocations.json` is the human register of `10.<net>.0.0/16` assignments. New products and
shared-services tenants consume the shared runtime VPC and therefore take **no** octet —
see `allocation_policy` in that file before adding an entry.
