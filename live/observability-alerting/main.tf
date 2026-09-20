# =============================================================================
# observability-alerting — everything that lives INSIDE the Grafana instance:
# the folder tree, the datasource lookup, the System Overview dashboard, and
# the Grafana Alerting pipeline (contact point, notification policy, alert rule
# groups).
#
# ── WHY THIS IS A SEPARATE STACK FROM `observability` (§ observability split) ─
# These resources are all managed through the Grafana INSTANCE HTTP API, so
# their provider needs a `url` and `auth` that are attributes of the
# `grafana_cloud_stack` and `grafana_cloud_stack_service_account_token`
# resources — which live in the `observability` stack. When both halves shared
# one stack, the provider was an ALIAS (`grafana.stack`) configured from those
# in-stack resources, and it could not configure during a plan of an empty
# state: the url and token are unknown until applied, so every resource under
# the alias failed with "the Grafana client is required for this resource".
# TF_VAR_grafana_cloud_api_key was never the problem — it was always passed.
#
# The fix is a two-stack apply order, identical in shape to cluster-dev reading
# cluster-prod: `observability` is applied first and EXPORTS the instance url
# and the service-account token; this stack reads them back via
# `terraform_remote_state` and configures ONE plain, non-aliased `grafana`
# provider from already-known values. Once `observability` is applied, this
# stack plans and applies with no ordering hazard.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    grafana = { source = "grafana/grafana", version = "~> 3.0" }
  }

  # Distinct state key from `observability` (platform/observability/…) — the two
  # stacks own disjoint resources and must never share a state file.
  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/observability-alerting/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

# Reads the `observability` stack's outputs for this stack's provider config —
# the same convention data-prod uses to read runtime-prod and bootstrap. The
# url and token are resolved at plan time from an ALREADY-APPLIED state, so the
# provider below configures from known values, unlike the old in-stack alias.
data "terraform_remote_state" "observability" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/observability/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# ONE, non-aliased provider. `url` and `auth` come from the sibling stack's
# outputs, not from resources in THIS plan — that is the whole point of the
# split. Both are known before any resource here is evaluated, so the client
# configures cleanly during plan.
provider "grafana" {
  url  = data.terraform_remote_state.observability.outputs.alerting_grafana_url
  auth = data.terraform_remote_state.observability.outputs.alerting_service_account_token
}

# Top-level parent for everything THIS repo's Terraform manages — the visual
# answer to "is this ours or Grafana Cloud's own stock content" (GrafanaCloud,
# Alert Groups Insights, Incident Insights, etc. stay at true top-level
# regardless; they're Grafana-managed and can never be re-parented under this).
resource "grafana_folder" "company" {
  title = "QNSC"
}

# One folder for every product's alert rules — matches the single-stack,
# label-scoped-tenancy design everything else here follows. A per-product
# folder would just be a filter UI already gives you via the `product` label.
resource "grafana_folder" "alerts" {
  parent_folder_uid = grafana_folder.company.uid
  title             = "Alerts"
}

# PARENT folder — each product gets its own SUBFOLDER underneath (see
# dashboards_folder_uid's own description for why this one is nested and
# alerts is not).
resource "grafana_folder" "dashboards" {
  parent_folder_uid = grafana_folder.company.uid
  title             = "Dashboards"
}

# Grafana's SLO app creates its own companion dashboard/folder per SLO by
# default (wherever `grafana_slo.folder_uid` points, or its own default
# location if unset). Giving every product's SLOs one shared home here, same
# reasoning as Alerts staying flat: SLO COUNT per product is small, a
# per-product subfolder would be premature.
resource "grafana_folder" "slos" {
  parent_folder_uid = grafana_folder.company.uid
  title             = "SLOs"
}

# Rally's own subfolder — created HERE, ONCE, not inside rally's own stack
# module. A real bug this shipped as: rally's develop and prod environments
# are separate Terraform ROOT MODULES with separate state files, so each
# one's `grafana_folder.product_dashboards` independently created its OWN
# "Rally" folder the moment prod applied for the first time — two real,
# separate folders with the same title, sitting as siblings, each holding
# only that one environment's dashboards. Centralizing it here is the same
# fix as `alerts_folder_uid`/`dashboards_folder_uid` already being resolved
# once and passed DOWN as a plain UID input, not re-derived per environment.
resource "grafana_folder" "rally_dashboards" {
  parent_folder_uid = grafana_folder.dashboards.uid
  title             = "Rally"
}

# opshub's own subfolder — same centralization as rally_dashboards above, done
# up front this time instead of discovered via a duplicate-folder incident.
resource "grafana_folder" "opshub_dashboards" {
  parent_folder_uid = grafana_folder.dashboards.uid
  title             = "Opshub"
}

# Resolved directly, not via a dashboard template variable: a Grafana
# dashboard template var of type "datasource" needs a populated `current`
# value to render correctly on a PROVISIONED (Terraform-loaded) dashboard,
# and that shape is exactly the kind of undocumented, easy-to-get-wrong
# JSON this session already got burned by twice (alert rule models,
# Fluent Bit config) — not worth the risk for zero benefit when there is
# only one datasource. Safe to look up directly here, unlike the earlier
# attempt in the single-stack form: THAT one broke because the service
# account token the read would authenticate with was being created in the
# SAME plan (a data source can't defer to apply the way a resource can). In
# this split the token is an INPUT from the already-applied `observability`
# stack, so this read is no longer racing its own credential's creation.
data "grafana_data_source" "prometheus" {
  name = data.terraform_remote_state.observability.outputs.alerting_prometheus_datasource_name
}

# ONE system-level dashboard, split by `service_namespace` (the product
# label observability-agent already stamps on every signal) rather than
# hardcoding a panel per product. Works today with only rally emitting
# data — one line per graph — and needs no edit when opshub/qnsc-kb-backend
# start pushing telemetry through the same stack: they show up as a second
# legend series automatically. A per-product dashboard (rally's own, more
# detailed) is a separate thing, owned by that product's own repo — see
# rally/infra's dashboard for why this split, not one giant dashboard here.
resource "grafana_dashboard" "system_overview" {
  folder    = grafana_folder.dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "System Overview"
    uid           = "system-overview"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-6h", to = "now" }
    refresh       = "1m"
    tags          = ["system", "provisioned"]

    panels = [
      # By (service_namespace, deployment_environment_name), not
      # service_namespace alone — a real gap caught before prod ever sent
      # data: with only develop emitting, these three panels HAPPENED to
      # look env-scoped, but the underlying query wasn't. The moment prod
      # activates, its numbers would have blended into the SAME line as
      # develop's (summed for rate/count, averaged into one ratio for
      # error rate) instead of showing as a second, separate series —
      # exactly the kind of silent merge a "which environment is actually
      # unhealthy" dashboard exists to prevent.
      {
        id         = 1
        title      = "HTTP request rate, by product + env"
        type       = "timeseries"
        gridPos    = { h = 8, w = 12, x = 0, y = 0 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [{
          expr         = "sum(rate(http_server_requests_total[5m])) by (service_namespace, deployment_environment_name)"
          legendFormat = "{{service_namespace}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id          = 2
        title       = "HTTP error rate, by product + env"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 12, y = 0 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit" } }
        # Confirmed live: production's line silently disappeared from this
        # panel's legend entirely (not "No data" text — just missing, easy to
        # miss) the moment it had zero 5xx errors in the window, because a
        # GROUPED numerator with one label combination entirely absent
        # doesn't merge with `or vector(0)` the way a plain sum() does — a
        # labelless vector(0) only fills in when the WHOLE result is empty,
        # not one missing group. The fix re-derives the same
        # (service_namespace, deployment_environment_name) label set from
        # the request-rate metric (guaranteed present for any product+env
        # that has ever served a request) zeroed out, so `or` has something
        # with the RIGHT labels to fall back to per group.
        targets = [{
          expr = join("", [
            "(",
            "sum(rate(http_server_errors_total[5m])) by (service_namespace, deployment_environment_name)",
            " or ",
            "sum(rate(http_server_requests_total[5m])) by (service_namespace, deployment_environment_name) * 0",
            ")",
            " / ",
            "sum(rate(http_server_requests_total[5m])) by (service_namespace, deployment_environment_name)",
          ])
          legendFormat = "{{service_namespace}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id          = 3
        title       = "HTTP p99 latency, by product + env"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 0, y = 8 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "ms" } }
        targets = [{
          expr         = "histogram_quantile(0.99, sum(rate(http_server_duration_milliseconds_bucket[5m])) by (le, service_namespace, deployment_environment_name))"
          legendFormat = "{{service_namespace}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id         = 4
        title      = "Active Mimir series (this stack, all products)"
        type       = "stat"
        gridPos    = { h = 8, w = 12, x = 12, y = 8 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        # Free tier ceiling is 10k series — this is the one number that
        # says "about to lose data silently" before it happens.
        targets = [{
          expr  = "count({__name__=~\".+\"})"
          refId = "A"
        }]
      },
    ]
  })
}

# ONE contact point, ONE root notification policy — this org has one
# on-call surface today (M365/Teams), so per-product routing would be
# complexity with nothing to route TO. The `product` label every rule group
# carries (see observability-alerts module) is what makes per-product
# routing a one-line addition later — a `policy` block keyed on
# `matcher { label = "product" ... }` — without touching any product's own
# Terraform.
#
# Gated on teams_webhook_url being set, unlike everything else in this
# "Alerting" section: Grafana's API genuinely REJECTS an empty `teams { url }`
# — this isn't the harmless-default pattern otlp_endpoint uses (an unset
# string there just means "no consumer configured yet"), it's a real
# validation failure at apply time. `count`, not `for_each` — there is
# exactly one of each, and count on a bool is simpler for a single
# on/off resource than a for_each over a conditional set.
locals {
  alerting_enabled = var.teams_webhook_url != ""
}

resource "grafana_contact_point" "teams" {
  count = local.alerting_enabled ? 1 : 0
  name  = "teams-alerts"

  teams {
    url = var.teams_webhook_url
  }
}

resource "grafana_notification_policy" "root" {
  count         = local.alerting_enabled ? 1 : 0
  contact_point = grafana_contact_point.teams[0].name
  # "env" is REQUIRED here, not "product" alone — caught in a pre-prod
  # audit, before it could bite: with only develop's alert rules active
  # this was invisible, but the moment prod's rules activate, a develop
  # "http-5xx-rate" firing and a prod "http-5xx-rate" firing would GROUP
  # INTO ONE Teams notification (same alertname, same product), reading
  # as one incident when it's two, in two different environments with two
  # completely different urgencies.
  group_by       = ["alertname", "product", "env"]
  group_wait     = "30s"
  group_interval = "5m"
  # Long repeat: a channel re-notified every default 4h for a still-firing
  # alert is exactly the kind of noise that trains people to ignore it.
  repeat_interval = "12h"
}

# Stack-wide, not per-product — lives here because the "Active Mimir series"
# panel it alerts on the same number as does too (System Overview dashboard,
# above). This is the free-tier-cap alert Grafana Cloud's own Cost
# Management/Usage Alerts feature would otherwise cover, EXCEPT that feature
# has no Terraform resource (checked the provider source directly — no
# usage/cost/billing resource exists), so it can only be built as code by
# reusing the same alerting pipeline every other rule in this stack already
# uses. 8000 = 80% of the 10k free-tier ceiling, a warning buffer before
# ingestion starts silently dropping series.
#
# NOT covering log/trace GB the same way: there is no Prometheus metric this
# stack's own Mimir exposes for "GB ingested this month" the way it exposes
# series count via `{__name__=~".+"}` — that number lives only in Grafana
# Cloud's billing backend. Set that one threshold by hand in Cost Management
# and Billing -> Usage Alerts (Logs, ~40 GiB) until Grafana ships a
# Terraform-manageable equivalent.
resource "grafana_rule_group" "series_near_cap" {
  count            = local.alerting_enabled ? 1 : 0
  name             = "platform (stack-wide)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  rule {
    name           = "mimir-series-near-free-tier-cap"
    condition      = "B"
    for            = "15m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 900
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "count({__name__=~\".+\"})"
        instant       = true
        range         = false
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    data {
      ref_id         = "B"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId      = "B"
        type       = "threshold"
        datasource = { type = "__expr__", uid = "__expr__" }
        expression = "A"
        conditions = [
          {
            evaluator = {
              type   = "gt"
              params = [8000]
            }
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    labels = {
      product  = "platform"
      severity = "warning"
    }

    annotations = {
      summary = "Active Mimir series across the whole stack (all products) is above 8000 — 80% of the 10k free-tier ceiling. New series will start being silently dropped past 10k."
    }
  }
}

variable "teams_webhook_url" {
  description = <<-EOT
    Microsoft Teams "Workflows" webhook URL (Teams' classic Incoming Webhook
    connectors were retired; this is a Logic Apps endpoint from a channel's
    Workflows app — "Post to a channel when a webhook request is received").
    Sensitive: treat like any other bearer credential embedded in a URL.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}
