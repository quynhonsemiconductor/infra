# ─────────────────────────────────────────────────────────────────────────────
# kb / dev — §17 step 2. THE FIRST WORKLOAD ON THE PLATFORM.
#
# qnsc-kb migrates first, and the risk is genuinely low despite being the largest
# product: PRODUCTION HAS NO STATE FILE, so only dev moves at this step. A failure
# here is a Tuesday, not an incident.
#
# It also proves more of the chart than anything else could — PgBouncer, the
# migrator role, the `worker` kind, KEDA, a 1.5 GB ONNX session needing a
# startupProbe, and the clamav sidecar, all at once.
#
# ── THIS FILE IS THE TEMPLATE FOR THE OTHER FIVE ────────────────────────────
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
    key            = "products/kb/dev/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

provider "postgresql" {
  host      = data.terraform_remote_state.data.outputs.postgres_host
  port      = 5432
  username  = "qnsc_admin"
  password  = data.aws_secretsmanager_secret_version.pg_admin.secret_string
  superuser = false
  sslmode   = "require"
}

data "aws_secretsmanager_secret_version" "pg_admin" {
  secret_id = "qnsc/dev/platform/postgres-admin"
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config  = { bucket = "qnsc-tofu-state", key = "platform/runtime-dev/terraform.tfstate", region = "ap-southeast-1" }
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

module "product" {
  source = "../../../../tf-modules/modules/product-profile"

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
  services = {
    api      = { needs_sqs = true, needs_s3 = true }
    worker   = { needs_sqs = true, needs_s3 = true }
    migrator = {}
  }

  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
  oidc_issuer       = data.terraform_remote_state.cluster.outputs.oidc_issuer

  shared_postgres = {
    host       = data.terraform_remote_state.data.outputs.postgres_host
    identifier = data.terraform_remote_state.data.outputs.postgres_identifier
  }

  vpc_id            = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.sg_rds_id
  kms_key_arn       = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
}
