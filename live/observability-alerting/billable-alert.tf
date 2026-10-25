# =============================================================================
# Billable-series alert — the guard for the meter the Free cap actually
# enforces (infra#214). `series_near_cap` (main.tf) watches the ACTIVE-series
# meter via a 5-min Mimir count; the 2026-09-22 breach of the org BILLABLE
# meter went unwarned by it (billable ran ~3.5× active on churn — measured
# figures in product-docs ONPREM-PLAN §12). This rule watches the breach
# directly, on the stack's Usage Insights datasource (org-level: no product
# or env dimensions exist — the labels below are set by the rule, which is
# also what routes it through grafana_notification_policy.root's
# env=production child: Teams + devops@, §12's routing).
#
# Threshold = the included allowance itself (10,000): crossing it means
# series are already being dropped — this is a breach siren, not a forecast.
# Re-evaluate downward once infra#213's Adaptive Metrics rules land and the
# 48-h re-measure gives a clean post-reduction baseline (§12).
# =============================================================================

data "grafana_data_source" "usage" {
  name = "grafanacloud-usage"
}

resource "grafana_rule_group" "billable_series" {
  name             = "platform (usage)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  rule {
    name           = "org-billable-series-over-included-allowance"
    condition      = "B"
    for            = "15m"
    no_data_state  = "OK"
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
      env      = "production" # routes through the notification policy's Teams child
      severity = "critical"
    }

    annotations = {
      summary = "Org billable series is over the Free tier's 10k included allowance — metric series are being dropped at ingestion. The Adaptive Metrics rules (infra#213) reduce this; if still firing after the 48-h re-measure, see ONPREM-PLAN §12 for the escalation path."
    }
  }
}
