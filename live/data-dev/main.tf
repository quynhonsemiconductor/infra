# ─────────────────────────────────────────────────────────────────────────────
# data-dev — the shared data tier for the DEV environment.
#
# §5d defines "shared" and §5 decides who is on it. Nothing created the instance
# itself: each product's own `infra/` owned its database, which is exactly the
# duplication this platform exists to remove — and, per §17b, exactly why the old
# stacks must be SHRUNK rather than destroyed, because one state owns both the
# database and the ECS services.
#
# ── DEV IS SHARED WITH NO EXCEPTIONS (§5) ───────────────────────────────────
# Not one instance per product. rova, opshub, qnsc-kb, LMS, solodesk and
# ai-dev-kit all get a database and two roles on the single instance below.
#
# The production split is different and decided on RESTORE GRANULARITY rather
# than cost — see data-prod. In dev there is nothing to restore, so there is
# nothing to split.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/data-dev/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = local.region
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/platform-dev/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# §7 — kms_key_arn lives in `bootstrap`, NOT in the network stack. Reading it from
# the wrong remote state is invisible to `terraform validate`: outputs are only
# resolved at plan time, so a name that does not exist looks fine until the first
# plan. Found in review, 2026-09-16.
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  region = "ap-southeast-1"
  env    = "dev"

  tags = {
    env       = local.env
    ManagedBy = "data-dev"
    Layer     = "platform"
    # §12 — cost allocation. Shared infrastructure carries no `product` tag by
    # definition, which is a real limit of per-product attribution and worth
    # knowing before the bill transfers: this line is split, not assigned.
    product = "shared"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# The shared Postgres instance
# ─────────────────────────────────────────────────────────────────────────────

# MODULE SOURCES ARE PINNED GIT REFS, never a relative path out of this repo.
#
# The first version of this stack used `../../../tf-modules/modules/rds`, which
# resolves on a laptop that happens to have the repositories side by side and
# NOWHERE ELSE. CI checks out one repository, so tflint reported "the module
# directory does not exist or cannot be read" for every module here — and the
# local `tofu validate` that was supposed to catch it passed, because the sibling
# directory was there.
#
# A pinned ref is also what makes a module upgrade a reviewable diff (§11), the
# same argument as the image tag.
module "postgres" {

  # ── §8's IAM AUTH NEEDED THIS AND NOBODY HAD TURNED IT ON ──────────────────
  #
  # The module defaults to false, and this stack never set it. Everything above that
  # layer was built as if it were true: §8 specifies IAM database auth,
  # `product-profile` creates roles that are members of `rds_iam` WITH NO PASSWORD,
  # and rova now mints a token per connection. The instance itself rejected every one
  # of them, and the only symptom was a readiness probe reporting
  #
  #     postgres: down — Failed query: SELECT 1
  #
  # with no mention of authentication anywhere in the chain. An `rds_iam` role cannot
  # fall back to a password, so this flag was the difference between the design
  # working and the database being unreachable by any route at all.
  #
  # SAFE TO ENABLE ON A LIVE INSTANCE, in the module's own words: "Additive: password
  # authentication keeps working, so turning this on changes nothing for a caller that
  # does not use it." For PostgreSQL it applies without a reboot.
  iam_database_authentication = true
  # checkov:skip=CKV_TF_1: a version TAG, not a commit hash, and that is the
  #   estate's convention — every other stack pins the same way
  #   (network-v1.3.1, cf-r2-v1.1.0, alb-logs-v1.0.1). release-please cuts these
  #   tags, so the ref is as immutable as a SHA in practice and a module upgrade
  #   stays a diff someone can read. `?ref=<40 hex chars>` would make the one
  #   line that says WHICH VERSION unreadable, in the change reviewers look at.
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/rds?ref=rds-v2.3.0"

  identifier        = "qnsc-shared-dev"
  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.sg_rds_id

  # §5 — db.t4g.small at $26.28/month, from the price recorded in
  # rova/infra/live/prod/main.tf:339. One instance for every dev database in the
  # estate, against ~$92/month for the six that exist today.
  instance_class       = "db.t4g.small"
  engine_version       = "16"
  allocated_storage_gb = 20
  multi_az             = false

  # §5d — "nothing in a development environment justifies an instance: not
  # restore, not noisy neighbours, not upgrade timing." One day of backups is
  # enough to undo an accident; anything more is paying to protect scratch data.
  backup_retention_days = 1
  deletion_protection   = false

  # §5d — "nothing in a development environment justifies an instance: not restore,
  # not noisy neighbours, not upgrade timing." One day of backups is enough to undo
  # an accident.
  #
  # NO `prevent_destroy`, and it is a gap rather than a decision — task 0.3. §5 made
  # this the single instance for six products, so destroying it blocks every
  # developer, not one person with scratch data. An attempt to add it on 2026-09-19
  # was reverted: OpenTofu 1.9.1, which this estate pins everywhere, rejects a
  # variable in a `lifecycle` block.
  skip_final_snapshot = true

  kms_key_arn = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
  tags        = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# The PREVIEW instance — §11
#
# Deliberately separate from the dev instance above, and §11 is explicit:
# "a shared 'preview' Postgres, a database per PR, dropped on close. NOT the dev
# instance — previews must not pollute dev data."
#
# A preview environment runs migrations from a pull request. Pointing that at the
# dev instance means an unreviewed migration reaches the environment everyone
# shares, which is the opposite of what previews are for.
# ─────────────────────────────────────────────────────────────────────────────

module "postgres_preview" {
  # checkov:skip=CKV_TF_1: a version TAG, not a commit hash, and that is the
  #   estate's convention — every other stack pins the same way
  #   (network-v1.3.1, cf-r2-v1.1.0, alb-logs-v1.0.1). release-please cuts these
  #   tags, so the ref is as immutable as a SHA in practice and a module upgrade
  #   stays a diff someone can read. `?ref=<40 hex chars>` would make the one
  #   line that says WHICH VERSION unreadable, in the change reviewers look at.
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/rds?ref=rds-v2.3.0"

  identifier        = "qnsc-preview"
  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.sg_rds_id

  instance_class       = "db.t4g.micro"
  engine_version       = "16"
  allocated_storage_gb = 20

  # Previews are capped at 5 concurrent with a 72h TTL (§11), and their databases
  # are dropped when the pull request closes. Nothing here is worth backing up.
  backup_retention_days = 0
  deletion_protection   = false
  skip_final_snapshot   = true


  kms_key_arn = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
  tags        = merge(local.tags, { purpose = "preview" })
}

# ─────────────────────────────────────────────────────────────────────────────
# The shared cache — §5d
#
# ONE instance, database index per product. An earlier draft of §5d said to remove
# Redis entirely; the measurement said otherwise:
#
#   qnsc-kb        Celery broker (broker = settings.REDIS_URL) + rate limiting
#   rova · opshub  app-platform/packages/platform-cache, plus ioredis in
#                  platform-http
#
# Celery must NOT move to SQS: the SQS transport drops `celery inspect` and
# `celery control`, priority queues, and caps ETA at 15 minutes. Worker
# introspection during an incident is worth more than $12/month to a team of three.
#
# So the decision is CONSOLIDATION, not removal — about $8/month, and the reason
# to do it anyway is that it stops the line growing with product count.
# ─────────────────────────────────────────────────────────────────────────────

module "cache" {
  # checkov:skip=CKV_TF_1: a version TAG, not a commit hash, and that is the
  #   estate's convention — every other stack pins the same way
  #   (network-v1.3.1, cf-r2-v1.1.0, alb-logs-v1.0.1). release-please cuts these
  #   tags, so the ref is as immutable as a SHA in practice and a module upgrade
  #   stays a diff someone can read. `?ref=<40 hex chars>` would make the one
  #   line that says WHICH VERSION unreadable, in the change reviewers look at.
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cache?ref=cache-v1.1.0"

  name              = "qnsc-shared-dev"
  mode              = "node"
  node_type         = "cache.t4g.micro"
  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.sg_cache_id
  kms_key_arn       = data.terraform_remote_state.bootstrap.outputs.kms_key_arn

  snapshot_retention_days = 0 # dev cache. Losing it costs a cold start.
  tags                    = local.tags
}
