# ─────────────────────────────────────────────────────────────────────────────
# kb / dev — §17 step 4.
#
# NOT the first workload any more. This file said "THE FIRST WORKLOAD ON THE
# PLATFORM" and §17 was reordered on 2026-09-17: rova goes first, because it is
# the product that matters and learning the platform on one nobody would notice
# teaches the wrong lessons. `live/rova-dev` is step 2.
#
# What kb still brings, and why it is step 4 rather than later: it PROVES MORE OF
# THE CHART than anything else could — PgBouncer, the migrator role, the `worker`
# kind, KEDA, a 1.5 GB ONNX session needing a startupProbe, and the clamav
# sidecar, all at once. rova exercises none of the last three, so whatever they
# break is found here.
#
# Its own risk is unchanged and still the lowest in the estate: qnsc-kb
# PRODUCTION HAS NO STATE FILE, so a failure at this step is a Tuesday.
#
# ── THIS FILE IS A TEMPLATE FOR THE OTHERS ──────────────────────────────────
# §17 migrates one product at a time, so the remaining stacks are written when
# their step arrives rather than all at once. Copy this, change the three identity
# values, and adjust the capability set.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    postgresql = { source = "cyrilgdn/postgresql", version = ">= 1.22" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "products/kb-dev/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

provider "postgresql" {
  # ── host ──────────────────────────────────────────────────────────────────
  # THE INSTANCE IS NOT PUBLICLY ACCESSIBLE (`publicly_accessible = false`), and it
  # sits in a private data subnet, so this provider cannot reach it from a laptop.
  # `var.postgres_host_override` is how you apply this stack through the SSM
  # port-forward `platform-dev`'s NAT instance exists to provide:
  #
  #   aws ssm start-session --target $(tofu -chdir=../platform-dev output -raw nat_instance_id) \
  #     --document-name AWS-StartPortForwardingSessionToRemoteHost \
  #     --parameters '{"host":["<postgres_host>"],"portNumber":["5432"],"localPortNumber":["15432"]}'
  #
  #   tofu apply -var postgres_host_override=localhost:15432
  #
  # Without the override the host came straight from remote state with no way to
  # substitute it, so there was no path to applying this stack at all — the tunnel
  # existed and nothing could use it.
  host = var.postgres_host_override != "" ? split(":", var.postgres_host_override)[0] : split(":", data.terraform_remote_state.data.outputs.postgres_host)[0]
  port = var.postgres_host_override != "" ? tonumber(split(":", var.postgres_host_override)[1]) : 5432

  # ── credentials ───────────────────────────────────────────────────────────
  # From the RDS-MANAGED secret, by ARN, decoded. Not a hand-made secret and not a
  # hardcoded username: see data-dev's `postgres_admin_secret_arn` output for the
  # three things that were wrong here before 2026-09-22.
  username  = jsondecode(data.aws_secretsmanager_secret_version.pg_admin.secret_string)["username"]
  password  = jsondecode(data.aws_secretsmanager_secret_version.pg_admin.secret_string)["password"]
  superuser = false
  sslmode   = "require"
}

variable "postgres_host_override" {
  type        = string
  default     = ""
  description = <<-EOT
    `host:port` to reach Postgres, for applying this stack through an SSM
    port-forward. Empty means use the private endpoint from data-*'s remote state,
    which only resolves from inside the VPC.
  EOT
}

data "aws_secretsmanager_secret_version" "pg_admin" {
  secret_id = data.terraform_remote_state.data.outputs.postgres_admin_secret_arn
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config  = { bucket = "qnsc-tofu-state", key = "platform/platform-dev/terraform.tfstate", region = "ap-southeast-1" }
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

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config  = { bucket = "qnsc-tofu-state", key = "platform/cluster-dev/terraform.tfstate", region = "ap-southeast-1" }
}

data "terraform_remote_state" "data" {
  backend = "s3"
  config  = { bucket = "qnsc-tofu-state", key = "platform/data-dev/terraform.tfstate", region = "ap-southeast-1" }
}

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
module "product" {
  # checkov:skip=CKV_TF_1: a version TAG, not a commit hash, and that is the
  #   estate's convention — every other stack pins the same way
  #   (network-v1.3.1, cf-r2-v1.1.0, alb-logs-v1.0.1). release-please cuts these
  #   tags, so the ref is as immutable as a SHA in practice and a module upgrade
  #   stays a diff someone can read. `?ref=<40 hex chars>` would make the one
  #   line that says WHICH VERSION unreadable, in the change reviewers look at.
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/product-profile?ref=product-profile-v0.1.0"

  # ── The three identity values ──────────────────────────────────────────────
  # These derive EVERY name this stack creates, and the Helm chart derives the
  # identical strings from the same three (§7c). Nothing crosses the repository
  # boundary; nothing can drift.
  #
  # `kb`, not `qnsc-kb` — §7c shortens the slug because AWS resources already
  # carry a `qnsc-` prefix and the long form double-prefixes.
  product = "kb"
  env     = "dev"

  # ⚠ MUST MATCH gitops/values/kb/dev.yaml. It is the ONE fact declared in both
  # repositories, and gitops/scripts/check-size-agreement.py fails when they
  # disagree — because OpenTofu picks an RDS instance class from it while the
  # chart picks replica counts and PDBs, and neither reads the other at plan time.
  size = "s"

  # §5 — dev is SHARED with no exceptions. qnsc-kb is dedicated in PRODUCTION
  # (pgvector, a ~16 GiB working set, a workload shape unlike anything else), and
  # that reasoning does not apply to a development database.
  postgres = {
    mode       = "shared"
    pooling    = "pgbouncer"
    extensions = ["vector", "pgcrypto"]
  }

  # §5d — one shared Valkey per environment, database index per product. The
  # module grants access; data-dev creates the instance.
  cache = { mode = "shared" }

  queue = { sqs = ["jobs"] }

  # §8 — created EMPTY. Values are written out of band and never enter state or
  # git. The path is hierarchical so the IRSA policy is one wildcard.
  secrets = [
    "database-url",
    "redis-url",
    "openrouter-key",
    "grafana-otlp-token",
  ]

  # Keys MUST match `services` in gitops/values/kb/base.yaml. A mismatch surfaces
  # as a pod that cannot assume anything, which is a slow way to find a typo.
  #
  # No `needs_s3`: object storage here is R2 (§7), which has no AWS IAM surface —
  # the credential is an API token under the secret prefix, already covered by the
  # one wildcard.
  services = {
    api      = { needs_sqs = true }
    worker   = { needs_sqs = true }
    migrator = {}
  }

  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
  oidc_issuer       = data.terraform_remote_state.cluster.outputs.oidc_issuer

  shared_postgres = {
    host       = data.terraform_remote_state.data.outputs.postgres_host
    identifier = data.terraform_remote_state.data.outputs.postgres_identifier
  }

  # §5d's allocation, copied from data-dev's `cache_host` output. TWO indexes:
  # qnsc-kb is the one product that uses the instance for two unrelated things,
  # and putting the Celery broker and the rate limiter on the same index would
  # let a `FLUSHDB` on either take out the other.
  shared_cache = {
    host       = data.terraform_remote_state.data.outputs.cache_host
    db_indexes = { broker = 0, ratelimit = 1 }
  }

  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.sg_rds_id
  kms_key_arn       = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
}
