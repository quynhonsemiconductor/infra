# =============================================================================
# kb prod monitoring — the `kb-prod.tf` the P3 plan reserves for this lane
# (PLAN-P3-PROD-LAUNCH-2026-11-04 §2.3 P8). kb prod does NOT exist yet (no
# namespace, no pg-kb, no kb.qnsc.vn record), so everything here is gated on
# `kb_prod_live` (default false) — a plan/apply today shows nothing.
#
# AVAILABILITY
# readyz (Synthetic Monitoring) plus the shared Kubernetes rules, which carry
# kb-prod as a target from the same change: CrashLoopBackOff
# (onprem-workloads.tf), missing replicas (onprem-incident-20261103.tf) and
# failed Jobs (onprem-data-p0.tf). pg-kb lives in data-prod like
# pg-rova/pg-opshub, so the Postgres-not-Ready rule already matches its pods,
# and the CNPG backup/replication rules are prod-data-plane wide (see
# prod-cnpg-backup.tf and onprem-k3s.tf) — kb needs no copy of them.
#
# 5xx RULE: kb HAS one now, in prod-http-5xx.tf (`kb-prod-http-5xx-rate`),
# alongside rova/opshub. The older claim in this header — that no
# `http_server_*` series exist for any product and kb publishes only its
# in-process /metrics — was WRONG and is corrected here (audit S-H2):
# qnsc-kb-backend#369 exports the same `http.server.duration` family over
# OTLP, and the series ARE in Mimir. They are aggregated by Adaptive Metrics,
# so a bare `{__name__=~"http_server_.*"}` query returns nothing/422; query
# them `sum by (job,status_class,deployment_environment_name)`. The rule is
# silent until a kb prod API serves traffic (no_data_state = OK).
#
# ── GATE ───────────────────────────────────────────────────────────────────
# `kb_prod_live` is flipped by ONE PR in the kb prod window, after the SA's
# edge/tunnel PR puts kb.qnsc.vn behind Access with a /readyz bypass. Creating
# the check before the host resolves would page from the first probe.
# The check ALSO needs `uptime_checks_enabled` and the SM token because its
# probe comes from the data source (uptime-dev.tf:44-47) — the same expression
# there, so `.probes["Singapore"]` is indexed only when the data source exists.
#
# ── ROUTING ────────────────────────────────────────────────────────────────
# env=production → grafana_notification_policy.root (Teams + devops@ email).
# =============================================================================

variable "kb_prod_live" {
  description = "Flip via a PR in the kb prod window (PLAN-P3 §2.3 P8) — the ONLY flip mechanism. Requires kb.qnsc.vn to resolve with a /readyz bypass; false = every resource below is culled."
  type        = bool
  default     = false
}

locals {
  kb_prod_live   = var.kb_prod_live
  kb_uptime_live = local.kb_prod_live && var.uptime_checks_enabled && var.grafana_sm_token != ""
}

# ── Synthetic Monitoring: kb prod readyz ───────────────────────────────────
# §12 budget: 5-minute check from ONE probe (Singapore) — ~8.64k
# executions/month. With rova prod (2 probes × 90 s), the two dev checks,
# opshub prod and this check the stack stays under the 100k free tier.
resource "grafana_synthetic_monitoring_check" "kb_prod_readyz" {
  count     = local.kb_uptime_live ? 1 : 0
  provider  = grafana.sm
  job       = "kb-prod-readyz"
  target    = "https://kb.qnsc.vn/readyz"
  frequency = 300000
  timeout   = 5000
  enabled   = true
  probes    = [data.grafana_synthetic_monitoring_probes.main[0].probes["Singapore"]]
  # No alert_sensitivity: SM legacy alerting is forbidden on new installations;
  # paging is the grafana_rule_group below on probe_success.

  labels = {
    product = "kb"
    env     = "production" # matches the notification policy matcher, NOT "prod"
  }

  settings {
    http {
      method = "GET"
      # kb serves /readyz as the alias of /health/ready (qnsc-kb-backend
      # src/api/main.py:1165) and answers 200 {"status":"ready",...}. Assert
      # the body: a 200 alone can come from the SPA when routing is wrong.
      fail_if_body_not_matches_regexp = ["\"status\":\"ready\""]
    }
  }
}

resource "grafana_rule_group" "kb_prod_readyz_down" {
  count            = local.kb_uptime_live ? 1 : 0
  name             = "kb (prod readyz)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name      = "kb-prod-readyz-down"
    condition = "B"
    for       = "5m"
    # The count gate above is the absent-target gate; once armed, a VANISHED
    # probe series (SM not publishing, check disabled outside tofu) must page,
    # not read as healthy.
    no_data_state  = "Alerting"
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
        expr          = "probe_success{job=\"kb-prod-readyz\"}"
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
      product  = "kb"
      env      = "production" # matches the notification policy matcher, NOT "prod"
      severity = "critical"
    }

    annotations = {
      summary = "Synthetic check kb-prod-readyz failing: https://kb.qnsc.vn/readyz has returned non-2xx/3xx (or timed out, or not {\"status\":\"ready\"}) for 5 minutes."
    }
  }
}
