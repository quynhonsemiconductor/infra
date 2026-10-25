# =============================================================================
# Billable-series alerts — the guard for the meter the Free cap actually
# enforces (infra#214). `series_near_cap` (main.tf) watches the ACTIVE-series
# meter via a 5-min Mimir count; this stack's org BILLABLE meter is a
# different measurement with its own ceiling, and it is the one whose breach
# drops series at ingestion. Two tiers:
#
#   WARNING (> 8,000, email only): no `env` label on purpose — the same
#   pattern as `series_near_cap` — so the notification policy's root
#   (devops@) handles it and the Teams child (env=production) never matches.
#
#   CRITICAL (> 10,000, Teams + devops@, `for` 1 h): gated behind
#   `billable_critical_enabled` (default false). It arms only after the
#   Adaptive Metrics rules (infra#213) have applied AND the 48-h
#   post-reduction re-measure shows billable under the allowance — until
#   then the warning tier carries the signal.
#
# BOTH rules use `no_data_state = "Alerting"` deliberately: if the usage
# series ever disappears (datasource renamed, token revoked), the rules FIRE
# instead of silently disarming the guard. The Usage Insights datasource
# (grafanacloud-usage) is org-level — it has no product or env dimensions,
# so the labels on each rule are static, which is exactly what makes the
# routing deterministic.
# =============================================================================

data "grafana_data_source" "usage" {
  name = "grafanacloud-usage"
}

resource "grafana_rule_group" "billable_series" {
  name             = "platform (usage)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  # WARNING tier — active now, email only (no env label → notification-policy root).
  rule {
    name           = "org-billable-series-warning"
    condition      = "B"
    for            = "15m"
    no_data_state  = "Alerting"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.usage.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.usage.uid }
        expr          = "grafanacloud_org_metrics_billable_series"
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
      summary = "Org billable series is above the Free tier's included allowance (warning line). Series are at risk of being dropped at ingestion; the recorded reductions (Adaptive Metrics rules, infra#213) bring this back down — re-measure 48 h after they apply."
    }
  }
}

variable "billable_critical_enabled" {
  description = "Arms the critical (> 10,000, Teams) billable rule. Flip via a PR AFTER infra#213's rules have applied and the 48-h re-measure shows billable under the allowance. false = the critical rule is culled; the warning tier stays active."
  type        = bool
  default     = false
}

# CRITICAL tier — gated: arms only via `billable_critical_enabled` (flip PR
# after infra#213's rules apply + the 48-h re-measure is under the allowance).
# env=production label routes it to Teams as well; `for` 1 h keeps a single
# ingest spike from paging.
resource "grafana_rule_group" "billable_series_critical" {
  count            = var.billable_critical_enabled ? 1 : 0
  name             = "platform (usage — breach)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  rule {
    name           = "org-billable-series-over-allowance"
    condition      = "B"
    for            = "1h"
    no_data_state  = "Alerting"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.usage.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.usage.uid }
        expr          = "grafanacloud_org_metrics_billable_series"
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
              params = [10000]
            }
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    labels = {
      product  = "platform"
      env      = "production"
      severity = "critical"
    }

    annotations = {
      summary = "Org billable series is over the Free tier's included allowance for over an hour — metric series are being dropped at ingestion. The Adaptive Metrics rules (infra#213) reduce this; if still firing after the 48-h re-measure, pause new ingestion sources and apply the recorded escalation steps."
    }
  }
}
