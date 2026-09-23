# ─────────────────────────────────────────────────────────────────────────────
# rova / dev — THE FIRST WORKLOAD ON THE PLATFORM.
#
# §17's table had rova LAST, on one argument: "the only product earning money".
# That is a real argument and it is overridden deliberately — rova is the product
# that matters, and learning the platform on one nobody would notice teaches the
# wrong lessons. See §17's reordering note.
#
# WHAT THE ORIGINAL ORDER BOUGHT, AND WHAT IT COSTS TO GIVE UP: qnsc-kb
# PRODUCTION HAS NO STATE FILE, so a kb-dev failure was a Tuesday. rova dev is a
# real environment developers use every day, so a failure here is visible. It is
# still dev, not revenue, and §17's cutover is reversible at every step — build
# alongside, run against the SAME database, cut the Cloudflare Tunnel hostname,
# roll back by pointing it back.
#
# DEV BEFORE PROD still holds, and is not the same question as which product goes
# first. rova prod is a separate stack, written when this one has soaked.
#
# ── THIS FILE IS THE TEMPLATE FOR THE OTHERS ────────────────────────────────
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
    key            = "products/rova-dev/terraform.tfstate"
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
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/product-profile?ref=product-profile-v0.8.0"

  # ── The three identity values ──────────────────────────────────────────────
  # These derive EVERY name this stack creates, and the Helm chart derives the
  # identical strings from the same three (§7c). Nothing crosses the repository
  # boundary; nothing can drift.
  #
  # `rova` — already short, so §7c's shortening does not apply here the way it
  # does to `qnsc-kb`.
  product = "rova"
  env     = "dev"

  # ⚠ MUST MATCH gitops/values/rova/dev.yaml. It is the ONE fact declared in both
  # repositories, and `ci/scripts/platform_conformance.py --only size` fails when
  # they disagree — because OpenTofu picks an RDS instance class from it while the
  # chart picks replica counts and PDBs, and neither reads the other at plan time.
  # (That check used to be gitops/scripts/check-size-agreement.py, which no longer
  # exists; the conformance script replaced it and this comment outlived it.)
  #
  # `s`, not `l`. rova is `l` in gitops/values/rova/base.yaml and dev.yaml
  # OVERRIDES it to `s` — size is a CRITICALITY tier, and a dev outage costs
  # nobody revenue. The conformance check compares the MERGED value, so this must
  # be what base+dev resolve to, not what base says.
  size = "s"

  # §5 — dev is SHARED with no exceptions, including for the product §5 dedicates
  # in production. rova prod gets its own instance because it is the only product
  # earning money; that reasoning does not reach a development database.
  #
  # No `extensions`: rova needs none. qnsc-kb's `vector` is for pgvector, which is
  # its whole reason for a dedicated instance — adding extensions here "to match"
  # would install something nothing uses.
  postgres = {
    mode    = "shared"
    pooling = "pgbouncer"
    # The schemas rova's migrations actually build. NOT `public`, which stays empty —
    # grants scoped there covered nothing and the app could not read a single table
    # ("permission denied for schema identity") despite 133 migrations succeeding.
    # Read from the applied database; add an entry when a migration adds a schema.
    app_schemas = ["work", "identity", "scm", "workspace", "messaging", "access", "notifications", "audit", "storage", "public"]
  }

  # §5d — one shared Valkey per environment, database index per product. The
  # module grants access; data-dev creates the instance.
  cache = { mode = "shared" }

  # §6b — rova has NO BullMQ and no general job queue. Its only SQS use is SES
  # bounce handling, which is why this is one queue and not a set. The design
  # records the same fact: "rova · opshub … NO BullMQ. Their only SQS use is SES
  # bounce handling."
  #
  # `email-bounce` is the PURPOSE, not a URL — the chart derives
  # `qnsc-dev-rova-email-bounce` from the same three identity values (§7c), and a
  # dead-letter queue comes with it.
  queue = { sqs = ["email-bounce"] }

  # §8 — created EMPTY. Values are written out of band and never enter state or
  # git. The path is hierarchical so the IRSA policy is one wildcard.
  #
  # Taken from what rova's ECS task definition injects today
  # (rova/infra/modules/stack/main.tf), so the migration is like-for-like rather
  # than a redesign of its configuration.
  #
  # DATABASE_PASSWORD is deliberately absent: §8 chose RDS IAM authentication, so
  # there is no database password to store or rotate. PgBouncer holds the endpoint
  # and the application reaches it at `pgbouncer:6432` in-namespace (§5d).
  secrets = [
    "database-url",
    "redis-url",
    "cookie-secret",
    "csrf-secret",
    "jwt-private-key",
    "entra-client-secret",
    "github-app-private-key",
    "github-webhook-secret",
    "storage-access-key-id",
    "storage-secret-access-key",
    "grafana-otlp-token",
  ]

  # Keys MUST match `services` in gitops/values/rova/base.yaml. A mismatch surfaces
  # as a pod that cannot assume anything, which is a slow way to find a typo.
  # `ci/scripts/platform_conformance.py --only services` is the check.
  #
  # No `needs_s3`: object storage here is R2 (§7), which has no AWS IAM surface —
  # the credential is an API token under the secret prefix, already covered by the
  # one wildcard.
  #
  # Only the WORKER gets SQS. rova's worker owns the CRON and RELAY loops — the
  # email relay, the Entra guest-invite relay and the notification outbox — so it
  # is the one that consumes the bounce queue. The api publishes nothing to it.
  # Widening this later is one word; granting it now is a permission nobody asked
  # for.
  services = {
    api      = {}
    worker   = { needs_sqs = true }
    migrator = {}
  }

  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
  oidc_issuer       = data.terraform_remote_state.cluster.outputs.oidc_issuer

  shared_postgres = {
    host       = data.terraform_remote_state.data.outputs.postgres_host
    identifier = data.terraform_remote_state.data.outputs.postgres_identifier
  }

  # §5d's allocation, copied from data-dev's `cache_host` output:
  #
  #     db 0  qnsc-kb   Celery broker
  #     db 1  qnsc-kb   rate limiting
  #     db 2  rova      platform-cache   <-- this stack
  #     db 3  opshub    platform-cache
  #
  # ONE index. rova uses the instance for one thing — app-platform's
  # `platform-cache` primitive — unlike qnsc-kb, which holds two.
  #
  # NOTE the change from today: rova's ECS develop stack sets `db_index = 0`,
  # which was correct when each environment's cache served fewer products. §15b
  # consolidates to one instance per environment, and 0 is qnsc-kb's broker — so
  # keeping 0 would put rova's cache and kb's Celery broker on the same index,
  # where a `FLUSHDB` on either takes out the other. This is a like-for-like
  # migration in every other respect; this one value must change.
  shared_cache = {
    host       = data.terraform_remote_state.data.outputs.cache_host
    db_indexes = { cache = 2 }
  }

  subnet_ids        = data.terraform_remote_state.network.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.network.outputs.sg_rds_id
  kms_key_arn       = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
}
