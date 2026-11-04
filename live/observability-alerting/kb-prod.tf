# =============================================================================
# kb prod monitoring — the `kb-prod.tf` the P3 plan reserves for this lane
# (PLAN-P3-PROD-LAUNCH-2026-11-04 §2.3 P8). kb prod does NOT exist yet (no
# namespace, no pg-kb, no kb.qnsc.vn record), so everything here is either
# flag-gated or carries a data-exists guard — a plan/apply today changes
# nothing that can fire.
#
# ── TWO GATES ──────────────────────────────────────────────────────────────
# * `kb_prod_live` (default false) — flipped by ONE one-word PR in the kb prod
#   window, after the SA's edge/tunnel PR puts kb.qnsc.vn behind Access with a
#   /readyz bypass. Creating the Synthetic check before the host resolves
#   would page from the first probe, which is why the check waits for the
#   flag and not just for absence.
# * the DATA-EXISTS guard inside the pg-kb backup rule (see below) — so the
#   rule is harmless even if the flag is flipped before the data layer syncs.
#
# ── AVAILABILITY ───────────────────────────────────────────────────────────
# readyz (Synthetic Monitoring) + the shared Kubernetes rules, which this PR
# extends to kb-prod: the CrashLoopBackOff rule (onprem-workloads.tf), the
# missing-replicas rule (onprem-incident-20261103.tf) and the failed-Job rule
# (onprem-data-p0.tf). pg-kb lives in data-prod like pg-rova/pg-opshub, so
# the Postgres-not-Ready rule already matches its pods.
#
# NO 5xx RULE FOR KB — deliberately, and this is a real gap rather than a
# decision: kb publishes only the in-process Prometheus text
# (`qnsc_http_requests_total` on /metrics, qnsc-kb-backend
# src/core/metrics.py) and nothing scrapes it; it has no `http_server_*` OTel
# series (its tracing resource sets no deployment.environment.name, and it
# instruments no HTTP metrics). The opshub 5xx rule therefore has no kb
# counterpart. Tracked as follow-up: scrape /metrics (or instrument kb's
# HTTP middleware) and add the rule with a verified series — a threshold over
# a series nobody has seen is exactly the silent-no-data alert the audit
# warned about.
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
  kb_prod_live = var.kb_prod_live

  # Same shape as rova-prod.tf's uptime_live: with no SM token the aliased
  # provider cannot configure and the probe data source would fail the plan.
  kb_uptime_live = local.kb_prod_live && var.uptime_checks_enabled && var.grafana_sm_token != ""
}

# ── Synthetic Monitoring: kb prod readyz ───────────────────────────────────
# §12 budget: 5-minute check from ONE probe (Singapore) — ~8.64k
# executions/month. With rova prod (2 probes × 90 s), the two dev checks and
# opshub prod the stack stays under the 100k free tier.
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
    name           = "kb-prod-readyz-down"
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

# ── kb prod: restarts + CNPG backup age ────────────────────────────────────
locals {
  kb_prod_app_rules = {
    restart_loop = {
      name = "kb-prod-container-restart-loop"
      # Same rationale as opshub's rule: CrashLoopBackOff misses a container
      # that restarts before the waiting reason settles (OOMKill loops).
      expr      = "max by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total{namespace=\"kb-prod\"}[15m]))"
      op        = "gt"
      threshold = 3
      for       = "5m"
      no_data   = "OK"
      product   = "kb"
      severity  = "warning"
      summary   = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) restarted more than 3 times in 15 minutes."
    }
    pg_backup_age = {
      name = "kb-pg-backup-too-old"
      # Same metric families and zero-filtering as the pg-rova rule; see
      # opshub-prod-app.tf for the DATA-EXISTS gate (the `or` branch exists
      # only while pg-kb's exporter does, so before the cluster exists the
      # rule stays silent instead of paging "no backup for 26 h").
      expr      = "time() - max by (cnpg_cluster) ({__name__=~\"cnpg_collector_last_available_backup_timestamp|barman_cloud_cloudnative_pg_io_last_available_backup_timestamp\", cnpg_cluster=\"pg-kb\"} > 0) or max by (cnpg_cluster) (cnpg_collector_up{cnpg_cluster=\"pg-kb\"}) * 0 + 1e9"
      op        = "gt"
      threshold = 26 * 3600
      for       = "15m"
      no_data   = "OK"
      product   = "kb"
      severity  = "critical"
      summary   = "No successful pg-kb base backup for over 26 hours (or the cluster reports and has no backup metric at all). WAL archiving alone cannot restore; check the ScheduledBackup and the R2 token."
    }
  }
}

resource "grafana_rule_group" "kb_prod_app" {
  count            = local.kb_prod_live ? 1 : 0
  name             = "kb (prod app)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.kb_prod_app_rules
    iterator = r
    content {
      name           = r.value.name
      condition      = "B"
      for            = r.value.for
      no_data_state  = r.value.no_data
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
          expr          = r.value.expr
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
                type   = r.value.op
                params = [r.value.threshold]
              }
            }
          ]
          intervalMs    = 1000
          maxDataPoints = 43200
        })
      }

      labels = {
        product  = r.value.product
        env      = "production" # matches the notification policy matcher, NOT "prod"
        severity = r.value.severity
      }

      annotations = {
        summary = r.value.summary
      }
    }
  }
}
