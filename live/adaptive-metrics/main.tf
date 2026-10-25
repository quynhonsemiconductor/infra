# =============================================================================
# Adaptive Metrics aggregation rules — applied AS CODE (org billable-series
# reduction, ONPREM-PLAN §12 rule 1; the private numbers, meters and dates
# live in product-docs ONPREM-PLAN §12 — this public repo carries none of
# them).
#
# PROVIDER: grafana/grafana-adaptive-metrics — pinned EXACTLY 0.4.0 (young
# provider, the same single-maintainer logic as the healthchecksio pin).
#
# AUTH (owner-decided): a DEDICATED access policy `terraform-adaptive-metrics`
# (realm qnsc, scope `adaptive-metrics-config:read+write` ONLY — no
# metrics:write), formatted `<metrics-instance-id>:<token>` — repo secret
# GRAFANA_ADAPTIVE_METRICS_API_TOKEN, created by the OWNER, mapped in
# infra-plan.yml (matrix-scoped to this stack) as
# TF_VAR_adaptive_metrics_api_key. The Prometheus URL is NOT secret: it is
# repo VARIABLE AM_METRICS_URL (no default here on purpose — a public repo
# does not carry infrastructure hostnames), mapped as
# TF_VAR_adaptive_metrics_url.
#
# WHY ITS OWN STACK, NOT observability-alerting: this provider CALLS the AM
# API while configuring — even with zero resource instances — so the stack's
# plan cannot pass without GRAFANA_ADAPTIVE_METRICS_API_TOKEN (401 at
# configure; proven in CI on the first cut, which lived inside
# observability-alerting). A count-gate keeps the plan EMPTY but not green.
# So this is a deliberately EXCLUDED stack, exactly like `observability`:
# infra-plan.yml lists `adaptive-metrics` in NOT_PLANNABLE (with this
# reason), infra-apply.yml does not manage it yet, and drift does not watch
# it. THE FLIP PR: owner adds the repo secret + the AM_METRICS_URL variable,
# then one PR that (a) flips `adaptive_metrics_live`, (b) removes
# `adaptive-metrics` from NOT_PLANNABLE, (c) adds it to infra-apply's
# selection loop and drift's matrix — the plan then shows exactly the four
# creates below, in CI, with no secrets.
#
# RULESET vs RULE — why individual `_rule` resources: `grafana-adaptive-metrics_ruleset`
# REPLACES the complete rule list of a segment on every apply, so it would
# destroy any recommendation-derived rules the owner applies later (and a
# later ruleset would destroy ours — the provider docs warn they conflict).
# `_rule` composes additively and stays scoped to our prefixes. We
# deliberately do NOT use the recommendations data source: these rules are
# reviewable in the PR instead of resolved at apply time. Consequence: if a
# ruleset is ever introduced, it must absorb these rules first (the docs'
# merge pattern).
#
# ── METRIC INVENTORY (count by (__name__), Mimir, 2026-10-25) ────────────────
# One rule per SERIES TYPE, because prefix + one aggregation list would apply
# sum:counter to gauge series under the same prefix:
#   http_server_   histogram (duration _bucket/_sum/_count),
#                  counters (requests_total, errors_total)   → rule 1
#   http_client_   histograms ×2 generations (seconds + milliseconds
#                  duration)                                 → rule 2
#   db_client_     histogram (operation duration)            → rule 3
#                  gauges (connection_count,
#                  connection_pending_requests, connection_max) → rule 4
#   (no http_server_active_requests / http_client_open_connections series
#   exist today; if a future SDK emits them they get their own exact rule —
#   the inventory above is re-checked at every flip.)
#
# ── AGGREGATION NAMES (evidence) ─────────────────────────────────────────────
# The provider passes `aggregations` through to the AM API verbatim (no
# validation in 0.4.0 — internal/model AggregationRule.Aggregations []string)
# in the AM API's `<fn>:<family>` grammar.
# EVIDENCE: provider 0.4.0's own examples establish `sum:counter`
# (examples/resources/grafana-adaptive-metrics_rule/resource.tf) and
# `sum:counter` + `avg:gauge` in ONE list
# (examples/.../merge_recommendations_with_custom_rules.tf — so a list MAY
# mix families). Docs: Grafana Cloud Adaptive Metrics API page
# https://grafana.com/docs/grafana-cloud/send-data/metrics/metrics-management/adaptive-metrics/adaptive-metrics-api/
# (SPA — needs JS; not machine-readable from here). `sum:histogram` (additive
# across _bucket/_sum/_count; quantiles keep working) and `sum:gauge` follow
# the same grammar. FLIP-PR DELIVERABLE: attach the
# `GET <url>/aggregations/recommendations` output FOR THESE EXACT METRICS
# (needs the token) — if `sum:histogram` or `sum:gauge` is rejected, the
# fallback is exact-match rules per series with the accepted names.
#
# COUNTER RESETS (pod restarts) + rate(): sum:counter emits a real counter
# series for the aggregate; per Mimir's aggregation semantics the per-input
# deltas are summed within each aggregation window, and an input reset is
# detected per-series BEFORE summation, so the aggregate only jumps by the
# surviving series' delta — rate() math on the aggregated series stays valid
# for the SLO recordings. VERIFY AT FLIP anyway: compare rate() on the
# aggregated http_server_requests_total against the raw series for one
# restart window before pointing any SLO at the aggregated series.
#
# ── KEEP-LABELS (allowlists — future labels collapse automatically) ─────────
# Sets verified against LIVE consumers: every product dashboard (rova
# overview+runtime, prod+develop; opshub overview+runtime) filters ONLY on
# `deployment_environment_name`; the System Overview histogram/panels group by
# (`service_namespace`, `deployment_environment_name`, `le`). The SLO
# definitions that match on `deployment_environment_name` are the Grafana
# SLO-app ones (folder QNSC/SLOs — NOT as-code in observability-alerting).
# `service_name` and `route`/`method`/`status_class` are kept for ad-hoc
# queries even though no dashboard reads them today; `le` on the
# operation-duration rule; `server_address` = the DB host (1–2 values,
# identifies the cluster; drop if it ever grows).
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
  description = "Flipped 2026-10-25 (this PR). false = every rule below is culled and plans show nothing."
  type        = bool
  default     = true
}

variable "adaptive_metrics_api_key" {
  description = "The owner's dedicated access policy `terraform-adaptive-metrics` (realm qnsc, scope adaptive-metrics-config:read+write ONLY — nothing wider), in the provider's '<metrics-instance-id>:<token>' format — repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN, created by the owner, mapped in infra-plan.yml (matrix-scoped to this stack). The infra-apply mapping will be added by the flip PR, together with this stack's selection loop."
  type        = string
  default     = ""
  sensitive   = true
}

variable "adaptive_metrics_url" {
  description = "Metrics host root — the AM API lives at /aggregations/* (verified: /aggregations/recommendations answers 401 there with no credentials, 404 under /api/prom). NO DEFAULT: supplied by repo variable AM_METRICS_URL → TF_VAR_adaptive_metrics_url (a public repo does not carry infrastructure hostnames)."
  type        = string
}

locals {
  am_live = var.adaptive_metrics_live

  # Labels every rule keeps: identity + env separation + (where they exist)
  # the HTTP semconv dimensions the products query.
  # `le` HERE, not just on the per-rule concat: BOTH http families are
  # histograms — a keep set without `le` aggregates the buckets away and
  # histogram_quantile() breaks (review round 2).
  am_keep_common = ["job", "service_namespace", "service_name", "deployment_environment_name"]
  am_keep_http   = concat(local.am_keep_common, ["method", "status_class", "le"])
  am_keep_db     = concat(local.am_keep_common, ["db_namespace", "db_operation_name", "db_system_name", "db_system", "server_address"])
}

provider "grafana-adaptive-metrics" {
  url     = var.adaptive_metrics_url
  api_key = var.adaptive_metrics_api_key
}

# Inbound request duration histogram + request/error counters.
resource "grafana-adaptive-metrics_rule" "http_server" {
  count      = local.am_live ? 1 : 0
  metric     = "http_server_"
  match_type = "prefix"

  keep_labels = concat(local.am_keep_http, ["route"])

  aggregations = ["sum:histogram", "sum:counter"]

  lifecycle {
    precondition {
      condition     = var.adaptive_metrics_api_key != ""
      error_message = "adaptive_metrics_api_key is empty — the owner must add repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN (access policy terraform-adaptive-metrics, scope adaptive-metrics-config:read+write, value '<metrics-instance-id>:<token>') before the flip."
    }
    precondition {
      condition     = var.adaptive_metrics_url != ""
      error_message = "adaptive_metrics_url is empty — set repo variable AM_METRICS_URL (the metrics host root, non-secret)."
    }
  }
}

# Outbound client request histograms (two duration-unit generations).
resource "grafana-adaptive-metrics_rule" "http_client" {
  count      = local.am_live ? 1 : 0
  metric     = "http_client_"
  match_type = "prefix"

  keep_labels = local.am_keep_http

  aggregations = ["sum:histogram", "sum:counter"]

  lifecycle {
    precondition {
      condition     = var.adaptive_metrics_api_key != ""
      error_message = "adaptive_metrics_api_key is empty — the owner must add repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN (access policy terraform-adaptive-metrics, scope adaptive-metrics-config:read+write, value '<metrics-instance-id>:<token>') before the flip."
    }
  }
}

# DB client operation duration histogram.
resource "grafana-adaptive-metrics_rule" "db_client_operation_duration" {
  count      = local.am_live ? 1 : 0
  metric     = "db_client_operation_duration_seconds"
  match_type = "prefix"

  keep_labels = concat(local.am_keep_db, ["le"])

  aggregations = ["sum:histogram"]

  lifecycle {
    precondition {
      condition     = var.adaptive_metrics_api_key != ""
      error_message = "adaptive_metrics_api_key is empty — the owner must add repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN (access policy terraform-adaptive-metrics, scope adaptive-metrics-config:read+write, value '<metrics-instance-id>:<token>') before the flip."
    }
  }
}

# DB connection gauges (connection_count, connection_pending_requests,
# connection_max — no `le`). BOTH aggregates on purpose: the Runtime &
# Dependencies panel reads the POOL TOTAL as sum() across pods → sum:gauge;
# saturation alerting wants the per-pod ceiling → max:gauge. The provider's
# own example already mixes families in one list; acceptance of both gauge
# functions together is verified at flip (see AGGREGATION NAMES).
resource "grafana-adaptive-metrics_rule" "db_client_connection" {
  count      = local.am_live ? 1 : 0
  metric     = "db_client_connection"
  match_type = "prefix"

  keep_labels = local.am_keep_db

  aggregations = ["sum:gauge", "max:gauge"]

  lifecycle {
    precondition {
      condition     = var.adaptive_metrics_api_key != ""
      error_message = "adaptive_metrics_api_key is empty — the owner must add repo secret GRAFANA_ADAPTIVE_METRICS_API_TOKEN (access policy terraform-adaptive-metrics, scope adaptive-metrics-config:read+write, value '<metrics-instance-id>:<token>') before the flip."
    }
  }
}
