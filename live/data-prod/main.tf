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
    key    = "platform/runtime-prod/terraform.tfstate"
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

module "postgres" {
  source = "../../../tf-modules/modules/rds"

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

  # §17b — this is production data. Both of these, and the `prevent_destroy`
  # below, exist because ONE Terraform state used to own both a database and the
  # ECS services beside it, and on 2026-09-14 that cost twelve minutes of downtime
  # and four snapshots taken for insurance.
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
  source = "../../../tf-modules/modules/cache"

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
