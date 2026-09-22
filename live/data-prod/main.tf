# ─────────────────────────────────────────────────────────────────────────────
# data-prod — the shared data tier for the DEV environment.
#
# §5d defines "shared" and §5 decides who is on it. Nothing created the instance
# itself: each product's own `infra/` owned its database, which is exactly the
# duplication this platform exists to remove — and, per §17b, exactly why the old
# stacks must be SHRUNK rather than destroyed, because one state owns both the
# database and the ECS services.
#
# ── THE PRODUCTION SPLIT, AND WHY IT IS NOT ABOUT COST ──────────────────────
#
#   rova      dedicated   the only product earning money        (product-profile)
#   qnsc-kb   dedicated   pgvector, ~16 GiB working set, a
#                         workload shape unlike anything else   (product-profile)
#   shared    HERE        opshub · LMS · solodesk · ai-dev-kit
#
# §5 measured the alternatives and the gap is about $40/month — too small to
# decide on. The decision is RESTORE GRANULARITY:
#
#   "RDS snapshots and point-in-time restore operate on an INSTANCE, not on a
#    database. If opshub needs a restore because someone deleted a table,
#    restoring the instance drags LMS, solodesk and Flagsmith back to the same
#    moment. The way out is restoring to a NEW instance and dumping one database
#    out of it — acceptable on a calm afternoon, miserable at 02:00 during the
#    incident that created the need."
#
# The five products on this instance have no independent restore requirement, no
# meaningful traffic, and no workload shape of their own. If one develops any of
# those it graduates — `mode = "shared"` becomes `"dedicated"` in its own
# product-profile call, which is the whole point of the capability being a value.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/data-prod/terraform.tfstate"
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
    key    = "platform/platform-prod/terraform.tfstate"
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
  env    = "prod"

  tags = {
    env       = local.env
    ManagedBy = "data-prod"
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

  identifier        = "qnsc-shared-prod"
  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.sg_rds_id

  # §5 — db.t4g.small at $26.28/month, from the price recorded in
  # rova/infra/live/prod/main.tf:339. One instance for every dev database in the
  # estate, against ~$92/month for the six that exist today.
  instance_class       = "db.t4g.small"
  engine_version       = "16"
  allocated_storage_gb = 50
  # §5 — Multi-AZ is opt-in at size L, and nothing on THIS instance is size L:
  # rova is, and rova is not here. Revisit if a product on it graduates to L
  # without graduating to its own instance, which would be a strange combination
  # worth questioning.
  multi_az = false

  # §13 — RPO/RTO by tier. The products here are XS, S and M: 24h/4h to 1h/2h,
  # which 7 days of PITR covers comfortably.
  backup_retention_days = 7

  # §17b — this is production data. Both of these exist because ONE Terraform state
  # used to own both a database and the ECS services beside it, and on 2026-09-14
  # that cost twelve minutes of downtime and four snapshots taken for insurance.
  #
  # ⚠ THERE IS STILL NO `prevent_destroy` HERE, AND THAT IS A KNOWN GAP — task 0.3.
  # This comment used to claim one ("Both of these, and the `prevent_destroy`
  # below"), which was false. An attempt on 2026-09-19 to add it as a module
  # variable was reverted: `lifecycle` blocks reject variables on OpenTofu 1.9.1,
  # which is what every workflow in this estate pins, and hardcoding `true` in the
  # module would block the RDS rebuild `docs/rova-subnet-group-rebuild.md`
  # documents, because `prevent_destroy` refuses replacement as well as deletion.
  #
  # So `deletion_protection` is the only control in force today. It makes the AWS
  # API refuse the call — which means OpenTofu plans a destroy cleanly and fails
  # part-way through applying it, rather than refusing to produce the plan. A
  # reviewer can still approve a green plan that deletes this instance.
  deletion_protection = true
  skip_final_snapshot = false

  kms_key_arn = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
  tags        = local.tags
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

  name              = "qnsc-shared-prod"
  mode              = "node"
  node_type         = "cache.t4g.micro"
  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.sg_cache_id
  kms_key_arn       = data.terraform_remote_state.bootstrap.outputs.kms_key_arn

  # Losing this loses qnsc-kb's queued Celery tasks, which is work rather than a
  # cold start — hence the retention (§5d: "a Celery broker that loses its queue
  # on restart loses work, so this wants persistence and failover").
  snapshot_retention_days = 3
  tags                    = local.tags
}
