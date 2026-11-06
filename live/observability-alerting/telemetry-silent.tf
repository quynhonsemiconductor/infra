# =============================================================================
# App-telemetry silence — the OTLP push died while the host is fine
# (observability audit 2026-11-06 §2). None of the existing rules catch this:
# the synthetic checks hit the edge, the 5xx rules need traffic, and a rule
# that reads metrics cannot see its own pipeline stopping.
#
# `target_info` is emitted once per OTLP resource by the collector. If a prod
# service stops producing it for 15 minutes, that product's whole telemetry
# stream is gone: dashboards go blank, every app rule silently becomes NoData,
# and nothing pages. One rule per prod service, so the alert names which one.
#
# WHY absent_over_time AND NOT `absent`: `absent(...)` is an instant check and
# flakes on one bad scrape; the 15-minute window matches the Alloy batch
# interval plus slack. `no_data_state = OK` because the expression itself
# RETURNS data (a 1) when the series is missing — NoData here would mean the
# rule failed to evaluate, which is not this rule's signal.
#
# VERIFY AT ROLLOUT: `count by (job) (target_info{deployment_environment_name="prod"})`
# must show the three jobs. If a product never emits target_info, delete its
# entry rather than let the rule fire immediately.
# =============================================================================

locals {
  prod_app_telemetry = {
    rova   = { job = "rova/rova-api" }
    opshub = { job = "opshub/opshub-api" }
    # kb intentionally ABSENT: no target_info{deployment_environment_name="prod"}
    # exists for kb/kb-api yet (kb-prod.tf records that prod series only arrived
    # with the launch), so arming it would page immediately. Add it when
    # `count by (job) (target_info{job="kb/kb-api", deployment_environment_name="prod"})`
    # returns 1.
  }
}

resource "grafana_rule_group" "app_telemetry_silent" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (app telemetry)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.prod_app_telemetry
    iterator = app

    content {
      name           = "k3s-${app.key}-telemetry-silent"
      condition      = "B"
      for            = "5m"
      no_data_state  = "OK"
      exec_err_state = "KeepLast"

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
          expr          = "absent_over_time(target_info{deployment_environment_name=\"prod\", job=\"${app.value.job}\"}[15m])"
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
                params = [0]
              }
            }
          ]
          intervalMs    = 1000
          maxDataPoints = 43200
        })
      }

      labels = {
        product  = app.key
        env      = "prod"
        severity = "critical"
      }

      annotations = {
        summary = "No telemetry from ${app.value.job} in production for 15 minutes — the OTLP push is dead or the service is not running. Dashboards and every app rule for this product are blind."
      }
    }
  }
}
