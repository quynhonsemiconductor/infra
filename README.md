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
| Object storage (`live/storage-dev`, `live/storage-prod`) | Cloudflare R2 buckets (per-product attachments, public assets, KB sources, ceo-suite backups). Provisioned here so the R2 admin token stays in one stack instead of every product's CI. Pins Cloudflare provider v5 |

## What belongs in **product** infra repos

Product-specific resources (ECS clusters, RDS, ElastiCache, SQS, ECR repos, IAM deploy roles) live in their own repos:
- `rova` — Rova product
- `opshub` — OpsHub product (internal IT/HR operations)
- `qnsc-kb-backend` — knowledge base (FastAPI + Celery)

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

## VPC allocation

`allocations.json` is the human register of `10.<net>.0.0/16` assignments. New products and
shared-services tenants consume the shared runtime VPC and therefore take **no** octet —
see `allocation_policy` in that file before adding an entry.
