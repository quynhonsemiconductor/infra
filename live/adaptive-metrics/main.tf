# =============================================================================
# Adaptive Metrics aggregation rules — applied AS CODE (org billable-series
# reduction, ONPREM-PLAN §12 rule 1). Context: the stack's org BILLABLE series
# is 16.4k vs 10k included (over since 2026-09-22, peak 21,107 on 2026-10-01);
# the churn labels below are why billable runs ~2× the concurrent active count.
#
# PROVIDER: grafana/grafana-adaptive-metrics — pinned EXACTLY 0.4.0 (young
# provider, v0.4.0 2026-09-24; the same single-maintainer logic as the
# healthchecksio pin). Auth = the owner's DEDICATED access policy
# `terraform-adaptive-metrics` (realm qnsc, scope `adaptive-metrics-config:read+write`
# ONLY — no metrics:write), formatted `<metrics-instance-id>:<token>` — repo
# secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN, created by the OWNER, mapped in
# infra-plan.yml (matrix-scoped) + infra-apply.yml (apply-observability-alerting
# only) as TF_VAR_adaptive_metrics_api_key. The Prometheus URL is NOT secret:
# plain variable below.
#
# WHY ITS OWN STACK, NOT observability-alerting: this provider CALLS the AM
# API while configuring — even with zero resource instances — so the stack's
# plan cannot pass without GRAFANA_ADAPTIVE_METRICS_API_TOKEN (401 at
# configure; proven in CI on the first cut, which lived inside
# observability-alerting). A count-gate keeps the plan EMPTY but not green.
# So this is a deliberately EXCLUDED stack, exactly like `observability`:
# infra-plan.yml lists `adaptive-metrics` in NOT_PLANNABLE (with this
# reason), infra-apply.yml does not manage it yet, and drift does not watch
# it. THE FLIP PR: owner adds the repo secret, then one PR that (a) flips
# `adaptive_metrics_live`, (b) removes `adaptive-metrics` from NOT_PLANNABLE,
# (c) adds it to infra-apply's selection loop and drift's matrix — the plan
# then shows exactly the three creates below, in CI, with no secrets.
#
# RULESET vs RULE — why individual `_rule` resources: `grafana-adaptive-metrics_ruleset`
# REPLACES the complete rule list of a segment on every apply, so it would
# destroy any recommendation-derived rules the owner applies later (and a
# later ruleset would destroy ours — the provider docs warn they conflict).
# `_rule` composes additively and stays scoped to our three prefixes. We
# deliberately do NOT use the recommendations data source: these rules are
# reviewable in the PR instead of resolved at apply time. Consequence: if a
# ruleset is ever introduced, it must absorb these rules first (the docs'
# merge pattern).
#
# GATING LIMITATION (differs from the product toggles): this provider CALLS
# the AM API while configuring — even with zero resource instances — so the
# stack's plan CANNOT pass until the owner adds the repo secret
# GRAFANA_ADAPTIVE_METRICS_API_TOKEN (401 "no credentials" otherwise; seen in
# CI on the PR that introduced this file). The count-gate still keeps the
# plan SHOWING nothing (no rules are created until the flip), but the green
# check needs the secret first. That is the provider's shape, not a choice.
#
# KEEP-LABELS, not drop-lists: any FUTURE label (the next semconv migration,
# a new resource attribute) collapses automatically instead of silently
# re-bloating billable. The keep sets are the labels verified on live series
# (Mimir, 2026-10-25) plus `le` for the histogram families:
#   http_server_: job, deployment_environment_name, route, method, status_class
#   http_client_: job, deployment_environment_name, method, status_class
#   db_client_:   job, deployment_environment_name, db_namespace,
#                 db_operation_name, db_system_name, db_system, server_address
# `deployment_environment_name` is KEPT on purpose: `job` does not separate
# dev from prod and the SLO rules + notification policy match on it.
# `server_address` on db_client_ is the DB host — 1–2 values today, identifies
# which cluster a latency series belongs to; drop it here if it ever grows.
#
# AGGREGATIONS (Mimir AM semantics, "<fn>:<family>"): histograms aggregate
# additively — `sum:histogram` covers _bucket, _sum and _count (p95-style
# quantiles keep working on the aggregated series); the request/error totals
# are counters — `sum:counter`. VERIFY AT FLIP against the AM recommendations
# API (GET <url>/aggregations/recommendations with the same token) before
# merging the flip PR — the API could not be reached pre-token (the current
# access policy carries no metrics scopes by design).
#
# FLIP = the same one-mechanism pattern as the product monitoring toggles:
# a PR-reviewed default change. The lifecycle precondition fails the flip PR
# if the token variable is still empty. Owner adds the repo secret first.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    grafana-adaptive-metrics = {
      source  = "grafana/grafana-adaptive-metrics"
      version = "0.4.0"
    }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/adaptive-metrics/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

variable "adaptive_metrics_live" {
  description = "Flip via a PR changing this default — the ONLY flip mechanism. false = every rule below is culled and plans show nothing."
  type        = bool
  default     = false
}

variable "adaptive_metrics_api_key" {
  description = "The owner's dedicated access policy `terraform-adaptive-metrics` (realm qnsc, scope adaptive-metrics-config:read+write ONLY), in the provider's '<metrics-instance-id>:<token>' format — repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN, created by the owner, mapped in infra-plan.yml (matrix-scoped) + infra-apply.yml (apply-observability-alerting only). No wider scope."
  type        = string
  default     = ""
  sensitive   = true
}

variable "adaptive_metrics_url" {
  description = "The AM API lives at the metrics host ROOT (`/aggregations/*`), not under /api/prom — verified: /aggregations/recommendations answers 401 (auth) there, 404 elsewhere."
  type        = string
  default     = "https://prometheus-prod-18-prod-ap-southeast-0.grafana.net"
}

locals {
  am_live = var.adaptive_metrics_live
}

provider "grafana-adaptive-metrics" {
  url     = var.adaptive_metrics_url
  api_key = var.adaptive_metrics_api_key
}

# Inbound request duration + totals (§12 rule 1). job = rova/rova-api,
# rova/rova-worker, opshub/* today; k3s-era products inherit the keep set.
resource "grafana-adaptive-metrics_rule" "http_server" {
  count      = local.am_live ? 1 : 0
  metric     = "http_server_"
  match_type = "prefix"

  keep_labels = [
    "job",
    "deployment_environment_name",
    "route",
    "method",
    "status_class",
    "le",
  ]

  aggregations = ["sum:histogram", "sum:counter"]

  lifecycle {
    precondition {
      condition     = var.adaptive_metrics_api_key != ""
      error_message = "adaptive_metrics_api_key is empty — the owner must add repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN (access-policy token, metrics:write, '<tenant-id>:<token>') before the flip."
    }
  }
}

# Outbound client requests (rova/opshub api+worker HTTP client histograms).
resource "grafana-adaptive-metrics_rule" "http_client" {
  count      = local.am_live ? 1 : 0
  metric     = "http_client_"
  match_type = "prefix"

  keep_labels = [
    "job",
    "deployment_environment_name",
    "method",
    "status_class",
    "le",
  ]

  aggregations = ["sum:histogram", "sum:counter"]

  lifecycle {
    precondition {
      condition     = var.adaptive_metrics_api_key != ""
      error_message = "adaptive_metrics_api_key is empty — the owner must add repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN (access-policy token, metrics:write, '<tenant-id>:<token>') before the flip."
    }
  }
}

# DB client operations (CNPG-era series keep the same shape; server_address =
# the DB host, kept: 1–2 values, identifies the cluster).
resource "grafana-adaptive-metrics_rule" "db_client" {
  count      = local.am_live ? 1 : 0
  metric     = "db_client_"
  match_type = "prefix"

  keep_labels = [
    "job",
    "deployment_environment_name",
    "db_namespace",
    "db_operation_name",
    "db_system_name",
    "db_system",
    "server_address",
    "le",
  ]

  aggregations = ["sum:histogram", "sum:counter"]

  lifecycle {
    precondition {
      condition     = var.adaptive_metrics_api_key != ""
      error_message = "adaptive_metrics_api_key is empty — the owner must add repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN (access-policy token, metrics:write, '<tenant-id>:<token>') before the flip."
    }
  }
}
