# =============================================================================
# Observability — the Grafana Cloud stack every product pushes telemetry to.
#
# This is the ONLY thing missing. Every product already carries the rest:
# `qnsc-tf-modules/modules/observability-agent` is a per-task OTel Collector
# SIDECAR, already wired into rally's api and worker tasks, currently a no-op
# because `otlp_endpoint` is unset — no shared collector, no ingress, no
# tunnel. A sidecar pushes OUTBOUND over the NAT egress every task already
# has; nothing needs to reach IN. See the module's own README for why tail
# sampling is deliberately not attempted there (needs a trace-id-aware
# gateway that does not exist yet — a real future gap, not this one).
#
# `qnsc-tf-modules/modules/observability` (CloudWatch alarms/dashboard) is a
# separate, already-wired, already-working thing. Nothing here touches it.
#
# THE ONE MANUAL STEP THIS STACK CANNOT DO ITSELF: Grafana Cloud organizations
# are not provisioned via API. Sign up at grafana.com (free, no card), create
# a Cloud Access Policy with scopes `stacks:read stacks:write
# stack-service-accounts:write`, and put its
# token in this repo's GRAFANA_CLOUD_API_KEY secret. Everything past that —
# the stack itself, and the push token every product's sidecar authenticates
# with — this file provisions.
#
# ── WHY THIS STACK IS SPLIT IN TWO (§ observability split) ───────────────────
# This stack holds ONLY the Grafana Cloud ORG-level resources: the stack, the
# access policies, and the stack service account + token. Every one of them is
# managed through the Grafana Cloud ORG API, authenticated by the default
# `grafana` provider below, which is configured purely from
# `var.grafana_cloud_api_key` — a value known BEFORE any plan. So this stack
# plans clean against an empty state today.
#
# Everything that lives INSIDE the Grafana instance (folders, dashboards, the
# datasource lookup, contact point, notification policy, alert rule groups) was
# split out into the sibling `observability-alerting` stack. Those resources are
# managed through the Grafana INSTANCE HTTP API, which needs a provider whose
# `url` and `auth` are `grafana_cloud_stack.qnsc.url` and
# `grafana_cloud_stack_service_account_token.alerting.key` — attributes of
# resources created HERE. A provider cannot be configured from resources it
# plans alongside (they are unknown until applied), which is precisely why the
# old single-stack, aliased-provider form failed every plan with "the Grafana
# client is required for this resource". `observability-alerting` reads THIS
# stack's outputs via `terraform_remote_state` and configures a single,
# already-known provider from them — the same apply-order dependency
# cluster-dev has on cluster-prod. Apply THIS stack first; then that one.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    grafana = { source = "grafana/grafana", version = "~> 3.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/observability/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "grafana" {
  cloud_access_policy_token = var.grafana_cloud_api_key
}

variable "grafana_cloud_api_key" {
  description = "Cloud Access Policy token (stacks:read, stacks:write, stack-service-accounts:write) — the one credential created by hand. See header comment."
  type        = string
  sensitive   = true
}

# One stack, all four products' dev+prod telemetry — tenancy is the
# product/environment resource attributes each sidecar sets, never a
# separate stack. Free tier at this org's volume (10k series / 50GB
# logs+traces+profiles / 14-day retention) — see the growth path in the
# reference design doc for what changes, and what doesn't, past it.
resource "grafana_cloud_stack" "qnsc" {
  name = "qnsc"
  slug = "qnsc"
  # "ap-southeast-0" was never a valid region_slug: the API silently accepted it
  # at create time and auto-assigned prod-ap-southeast-1 instead of erroring —
  # the WRONG region, confirmed by the access-policy API refusing to attach to
  # it ("Stack must be in region prod-ap-southeast-0"). This is the real,
  # correct region; matching it forces a genuine destroy+recreate of the
  # misplaced stack, safe here since it holds zero data.
  region_slug = "prod-ap-southeast-0"
}

# Scoped write-only: this is what every product's sidecar authenticates
# with, so it carries no read/admin surface a leaked task credential could
# use beyond ingest.
resource "grafana_cloud_access_policy" "otlp_push" {
  region       = "prod-ap-southeast-0" # access-policy API uses a different region-slug format than the stack's
  name         = "otlp-sidecar-push"
  display_name = "OTel sidecar push — write-only"

  scopes = ["metrics:write", "logs:write", "traces:write"]

  realm {
    type       = "stack"
    identifier = grafana_cloud_stack.qnsc.id
  }
}

resource "grafana_cloud_access_policy_token" "otlp_push" {
  region           = "prod-ap-southeast-0"
  access_policy_id = grafana_cloud_access_policy.otlp_push.policy_id
  name             = "otlp-sidecar-push-token"
}

# =============================================================================
# Alerting credential — the STACK SERVICE ACCOUNT lives here (org-level), but
# every resource it authenticates is in the sibling `observability-alerting`
# stack. This stack CREATES the credential; that stack CONSUMES it via this
# stack's outputs. See the split rationale in the header.
#
# Grafana Alerting runs ALONGSIDE CloudWatch Alarms, not replacing it.
# CloudWatch Alarms stay on infra-level signals (ECS task health, ALB target
# health); Grafana Alerting covers only what CloudWatch cannot see — the
# application-level telemetry this stack ingests (DB pool pressure, HTTP
# error rate, latency, in-process circuit breakers).
#
# A SECOND, DIFFERENT credential from otlp_push above: the alerting resources
# (contact point, notification policy, rule groups — now in
# `observability-alerting`) live INSIDE the Grafana instance itself and are
# managed through the Grafana HTTP API, not the Grafana Cloud ORG API
# `cloud_access_policy_token` authenticates to. Even with
# `stack-service-accounts:write` added (real 403 hit on first apply —
# `stacks:read stacks:write` alone does not cover creating a stack service
# account, and that scope is what fixed it), the ORG token still cannot
# create an ALERT RULE inside the stack; it can only create the service
# account below, which is what CAN. A stack-scoped SERVICE ACCOUNT is the
# credential for that surface — same split Grafana's own docs draw between
# "Cloud API" and "Grafana instance API".
#
# `role = "Admin"`, NOT "Editor" — reversed from an earlier attempt, by two
# real, distinct 403s, not by preference. Editor's basic role decomposes
# into fixed roles that do not include reading an arbitrary folder by UID
# (only the special General folder), so the very first Terraform read-back
# after creating a folder failed. Granting the missing `fixed:folders:writer`
# role explicitly seemed like the least-privilege fix — but ASSIGNING a
# role is ITSELF gated behind `users.roles:add/remove` /
# `teams.roles:add/remove`, which Editor also lacks, and a service account
# cannot grant itself permissions it does not already have. That's a genuine
# dead end, not a missing scope to add: an Editor-scoped automation
# principal cannot self-provision the folder RBAC an Editor-scoped
# automation principal needs. Admin is the correct role for a Terraform
# principal managing folders + alert rules + notification policy end to
# end, not an unneeded broadening.
resource "grafana_cloud_stack_service_account" "alerting" {
  stack_slug = grafana_cloud_stack.qnsc.slug
  name       = "terraform-alerting"
  role       = "Admin"
}

resource "grafana_cloud_stack_service_account_token" "alerting" {
  stack_slug         = grafana_cloud_stack.qnsc.slug
  service_account_id = grafana_cloud_stack_service_account.alerting.id
  name               = "terraform-alerting-token"
  # No expiration set deliberately: this token is Terraform's own long-lived
  # management credential for the alerting surface, analogous to otlp_push's
  # token never rotating on a timer. Rotate by tainting this resource if it
  # ever needs to change, same as any other provider credential would.
}
