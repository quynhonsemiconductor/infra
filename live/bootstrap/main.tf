terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/bootstrap/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org       = "qnsc"
      ManagedBy = "opentofu"
      Layer     = "platform"
    }
  }
}

locals {
  # Cloudflare IPv4 ranges (https://cloudflare.com/ips-v4). An external,
  # account-wide constant — every product that fronts its ALB with Cloudflare
  # locks ingress to these. Exported so a range change is ONE edit here, not N
  # copies across product prod stacks.
  cloudflare_ipv4 = [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22",
    "103.31.4.0/22", "141.101.64.0/18", "108.162.192.0/18",
    "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22",
    "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
  ]
}

# ── Shared State Backend ──────────────────────────────────────────────────────
module "state_backend" {
  source         = "../../modules/state-backend"
  bucket_name    = "qnsc-tofu-state"
  dynamodb_table = "qnsc-tofu-locks"
  tags           = { Layer = "platform" }
}

# ── GitHub OIDC Provider ──────────────────────────────────────────────────────
# One per AWS account. Product infra repos reference this ARN via remote_state.
module "oidc_provider" {
  source = "../../modules/oidc-provider"
  tags   = { Layer = "platform" }
}
# ── Shared Customer-Managed KMS Key ────────────────────────────────────────────────────
# One CMK per account, alias/qnsc-platform.
# Used by: RDS (storage encryption), Secrets Manager, S3 SSE-KMS.
# Product infra reads the ARN from this stack's remote state.
module "kms" {
  source = "../../modules/kms"
  tags   = { Layer = "platform" }
}

# ── Shared Artifacts S3 Bucket ────────────────────────────────────────────────────────
# Central store for cross-repo build artifacts:
#   openapi/{product}/{env}/{sha}/openapi.json  ← immutable
#   openapi/{product}/{env}/latest/openapi.json ← mutable pointer
# Used by: rally-api CI (publish-openapi-spec action), rally-web CI (codegen).
module "artifacts_bucket" {
  source      = "../../modules/artifacts-bucket"
  bucket_name = "qnsc-artifacts"
  kms_key_arn = module.kms.key_arn
  tags        = { Layer = "platform" }
}

# ── The Helm chart's OCI registry — task 1.8, §11c ──────────────────────────
#
# WITHOUT THIS, NOTHING DEPLOYS. `gitops/appsets/products.yaml` gives every
# Application a source of:
#
#   repoURL: 608983206583.dkr.ecr.ap-southeast-1.amazonaws.com
#   chart:   charts/qnsc-service
#
# and ECR does not create a repository on first push. So `chart-release.yaml` has
# nowhere to push, ArgoCD has nothing to resolve, and every Application — rova-dev
# included — fails at source resolution rather than at anything that looks like a
# cause. Found 2026-09-19 while tracing the delivery path end to end; task 1.8
# required `image_tag_mutability = IMMUTABLE` on this repository and the
# repository itself was never declared anywhere.
#
# WHY IT LIVES IN `bootstrap` AND NOT PER PRODUCT OR PER ENVIRONMENT.
# The chart is ONE artefact the whole estate shares, versioned rather than
# environment-scoped — which is §7c's argument against a per-environment image
# repository, applied to the chart. `live/<product>-shared` is the home for
# product ECR (repository-boundaries.md), and the chart is not a product.
# `bootstrap` already owns the other account-wide artefact store
# (`artifacts_bucket`) and the CMK both are encrypted with, so this is the same
# class of thing in the same place.
#
# IMMUTABLE MATTERS MORE HERE THAN ON AN IMAGE. Every Application pins
# `targetRevision: "0.1.0"`. If that version can be rewritten underneath them, one
# `helm push` silently changes the rendered manifests of every product in both
# environments at once — the single widest blast radius in the estate. §11c: "a
# version cannot be rewritten."
#
# NOTHING EXPIRES A CHART VERSION, and that is deliberate rather than a gap in the
# module's lifecycle policy. The module writes three rules, keyed on tag PREFIX:
# untagged after 1 day, `v*` after `release_retention_days`, and the newest
# `sha-*` by count. `helm push` tags with Chart.yaml's version — `0.1.0` — which
# matches neither prefix, so only the untagged rule can ever apply, and that one
# only reaps orphaned layers. This is load-bearing: an expired chart version
# breaks every Application pinned to it, and the failure arrives at the next sync,
# long after the push that caused it.
module "chart_registry" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/ecr?ref=ecr-v2.1.0"

  repository_names = ["charts/qnsc-service"]

  # Task 1.8, §11c. Also the module's default — stated anyway, because this is the
  # one repository where mutability would reach every product at once.
  image_tag_mutability = "IMMUTABLE"

  kms_key_arn = module.kms.key_arn
  tags        = { Layer = "platform" }
}

# ── GitHub OIDC — this repo's own infra-plan/infra-apply roles ──────────────
# plan.yml/apply.yml assume qnsc-github-infra-plan / qnsc-github-infra-apply.
# environments left empty — no per-environment app deploy role needed here
# (this repo only ever runs plan/apply, never deploys an app). app_repo_names
# can't be empty: the ecr-push role's trust policy needs at least one real
# repo in its condition or the policy is invalid; qnsc-infra never actually
# pushes images, so this role stays unused but harmless.
#
# NOTE: no infra_apply_guardrail here. This IS the platform stack that legitimately
# manages the state bucket / lock table / OIDC provider / CMK, so it must retain
# full control over them — the guardrail is for product applies (rally/opshub) that
# must never touch these foundations. v2.0.1 default infra_apply_subjects
# (environment:shared|develop|production) already match this repo's apply jobs.
module "iam_oidc" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/iam-oidc?ref=iam-oidc-v3.0.1"

  product           = "qnsc"
  oidc_provider_arn = module.oidc_provider.arn

  github_org             = "quynhonsemiconductor"
  environments           = {}
  app_repo_names         = ["infra"]
  infra_repo_name        = "infra"
  ecr_repository_pattern = "qnsc-*"
  ecs_passrole_pattern   = "qnsc-*"
  tags                   = { Layer = "platform" }
}