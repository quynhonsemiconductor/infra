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

## What belongs in **product** infra repos

Product-specific resources (ECS clusters, RDS, ElastiCache, SQS, ECR repos, IAM deploy roles) live in their own repos:
- `rova` — Rova product
- `opshub` — OpsHub product

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
  rally/shared/terraform.tfstate           ← rally-infra _shared
  rally/develop/terraform.tfstate          ← rally-infra develop
  rally/prod/terraform.tfstate             ← rally-infra prod
  opshub/shared/terraform.tfstate          ← opshub-infra _shared
  opshub/develop/terraform.tfstate         ← opshub-infra develop
  opshub/prod/terraform.tfstate            ← opshub-infra prod
```
