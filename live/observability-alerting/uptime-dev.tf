# =============================================================================
# Uptime for the on-prem dev estates — FAST TRACK (owner 2026-11-01).
#
# rova prod leaves AWS in 1–2 days and team traffic moves to the on-prem
# cluster earlier than the full §12 collector. Until the k8s collector ships
# there are NO Kubernetes metrics to alert on — but uptime can be watched from
# Grafana Synthetic Monitoring today, because the `/readyz` endpoints are real
# and public.
#
# This file adds the two missing dev checks and OWNS the flag that arms all
# three fast-track checks (rova prod lives in rova-prod.tf, whose readyz
# resources point at `local.uptime_live` there):
#
#   rova.qnsc.vn/readyz        prod  — the target of the move
#   rova-dev.qnsc.vn/readyz    dev
#   opshub-dev.qnsc.vn/readyz  dev
#
# §12 budget: these are three of the SIX five-minute checks the plan budgets
# (one probe, ≤ 10 checks); the remaining slots are opshub prod, kb-dev and one
# spare. No new probe is added.
#
# ── WHY THE PROBE ID COMES FROM A DATA SOURCE ───────────────────────────────
# The Stage-D flip procedure assumed a human reads the probe id out of the SM
# UI and hard-codes it. The fast track does not have a human in the loop: the
# probes data source reads the SM API with the same token the resources use and
# pins the name "Frankfurt" in git. One probe for the whole estate (§12).
#
# ── GATE ────────────────────────────────────────────────────────────────────
# `uptime_checks_enabled` defaults true: the PR is the review, and the merge is
# the arming. The plan still shows nothing when GRAFANA_SM_TOKEN is empty (the
# aliased provider cannot configure, and every instance is culled) — so a
# missing secret degrades to "no checks", never to a failed apply.
# =============================================================================

variable "uptime_checks_enabled" {
  description = "Arms the fast-track uptime checks (rova prod + rova-dev + opshub-dev readyz) and their rules. Also honoured by rova-prod.tf's readyz resources. Requires GRAFANA_SM_TOKEN; with an empty token everything is culled."
  type        = bool
  default     = true
}

# The aliased SM provider (monitoring-providers.tf) authenticates the data
# source; count keeps it out of the graph when the flag or the token is absent.
data "grafana_synthetic_monitoring_probes" "main" {
  count    = var.uptime_checks_enabled && var.grafana_sm_token != "" ? 1 : 0
  provider = grafana.sm
}

# ── rova-dev ────────────────────────────────────────────────────────────────
resource "grafana_synthetic_monitoring_check" "rova_dev_readyz" {
  count     = local.uptime_live ? 1 : 0
  provider  = grafana.sm
  job       = "rova-dev-readyz"
  target    = "https://rova-dev.qnsc.vn/readyz"
  frequency = 300000
  timeout   = 5000
  enabled   = true
  probes    = [data.grafana_synthetic_monitoring_probes.main[0].probes["Frankfurt"]]
  # No alert_sensitivity: SM legacy alerting is forbidden on new installations
  # ("legacy alerts usage is forbidden"); paging is the grafana_rule_group below
  # on probe_success.

  labels = {
    product = "rova"
    env     = "development" # NOT "production": dev uses the paging=teams policy below
  }

  settings {
    http {
      method = "GET"
    }
  }
}

resource "grafana_rule_group" "rova_dev_readyz_down" {
  count            = local.uptime_live ? 1 : 0
  name             = "rova (dev readyz)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "rova-dev-readyz-down"
    condition      = "B"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 300
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "probe_success{job=\"rova-dev-readyz\"}"
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
              type   = "lt"
              params = [1]
            }
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    # `paging = teams` is what routes a DEV alert to Teams: the root policy
    # sends dev to email only unless this label is present (main.tf).
    labels = {
      product  = "rova"
      env      = "development"
      paging   = "teams"
      severity = "critical"
    }

    annotations = {
      summary = "Synthetic check rova-dev-readyz failing: https://rova-dev.qnsc.vn/readyz has returned non-2xx/3xx (or timed out) from the SM probe for 5 minutes."
    }
  }
}

# ── opshub-dev ──────────────────────────────────────────────────────────────
resource "grafana_synthetic_monitoring_check" "opshub_dev_readyz" {
  count     = local.uptime_live ? 1 : 0
  provider  = grafana.sm
  job       = "opshub-dev-readyz"
  target    = "https://opshub-dev.qnsc.vn/readyz"
  frequency = 300000
  timeout   = 5000
  enabled   = true
  probes    = [data.grafana_synthetic_monitoring_probes.main[0].probes["Frankfurt"]]
  # No alert_sensitivity: SM legacy alerting is forbidden on new installations
  # ("legacy alerts usage is forbidden"); paging is the grafana_rule_group below
  # on probe_success.

  labels = {
    product = "opshub"
    env     = "development"
  }

  settings {
    http {
      method = "GET"
    }
  }
}

resource "grafana_rule_group" "opshub_dev_readyz_down" {
  count            = local.uptime_live ? 1 : 0
  name             = "opshub (dev readyz)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "opshub-dev-readyz-down"
    condition      = "B"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 300
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "probe_success{job=\"opshub-dev-readyz\"}"
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
              type   = "lt"
              params = [1]
            }
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    labels = {
      product  = "opshub"
      env      = "development"
      paging   = "teams"
      severity = "critical"
    }

    annotations = {
      summary = "Synthetic check opshub-dev-readyz failing: https://opshub-dev.qnsc.vn/readyz has returned non-2xx/3xx (or timed out) from the SM probe for 5 minutes."
    }
  }
}
