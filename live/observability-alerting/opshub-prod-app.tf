# =============================================================================
# opshub prod — APPLICATION and DATA alerts (P3 launch, 2026-11-04).
#
# Companion to opshub-prod.tf, which owns the two checks that need an external
# service (the Synthetic Monitoring readyz probe and the Healthchecks.io batch
# pings) and is gated on `opshub_prod_live`. THIS file needs no flag: every
# rule reads a series that exists only once opshub prod does, and every
# absence-sensitive rule carries an explicit data-exists guard (see the
# backup-age rule). Arming it now therefore pages from the first request, not
# from a flip PR — the launch window (P3 C5-C9) is exactly when a 5xx or a
# crash loop matters most, and the flag in opshub-prod.tf is only flipped at
# the END of that window.
#
# ── WHAT IS NOT HERE ───────────────────────────────────────────────────────
# * CrashLoopBackOff for opshub-prod — the shared prod rule in
#   onprem-workloads.tf already selects it (namespace list there now carries
#   kb-prod too); a second rule would double-page the same pods.
# * Deployment missing replicas — onprem-incident-20261103.tf's
#   k3s-deployment-unavailable-prod.
# * Failed Jobs — onprem-data-p0.tf's k3s-job-failed (data-prod covers the
#   pg-opshub dump/backup Jobs; opshub-prod covers the migrator PreSync Job).
# * CNPG replication lag — onprem-k3s.tf's k3s-cnpg-replication-lag has no
#   cluster filter, so pg-opshub is already covered (single instance on day 1:
#   the series is absent and no_data_state = OK keeps it silent).
# * Postgres not Ready — onprem-workloads.tf's pg-rova rule matches every
#   `pg-<name>-<n>` pod in data-prod, so pg-opshub is covered.
# * Dump/restore misses — Healthchecks.io owns the batch-job pings
#   (opshub-prod.tf), by design.
#
# ── `env` vs `deployment_environment_name` ─────────────────────────────────
# infra#350 adds the collector's `env="dev"|"prod"` label for app metrics
# (gitops#242). It is NOT usable here: Adaptive Metrics aggregates any label
# that is not in a rule's keep_labels, and the `http_server_` rule in
# live/adaptive-metrics keeps `deployment_environment_name` (not `env`) — the
# same caveat #350 documents for its own panels. So the 5xx rule selects
# `deployment_environment_name = "prod"`, which the keep-list guarantees
# survives, and the value is what the observability package derives from
# DEPLOYMENT_ENV (`prod` in values/opshub/prod.yaml).
#
# ── ROUTING ────────────────────────────────────────────────────────────────
# env=production → grafana_notification_policy.root (Teams + devops@ email),
# the same child policy every prod rule in this stack uses.
# =============================================================================

locals {
  opshub_prod_app_rules = {
    http_5xx = {
      name = "opshub-prod-http-5xx-rate"
      # Share of REAL 5xx (not the errors counter, which also counts 4xx —
      # app-platform's HttpMetrics.record increments it for every >= 400). The
      # duration histogram carries status_class, and its _count series is the
      # per-request count with that label. `job` is `<product>/<service>` for
      # OTLP app series (rova-mcp.tf verified the shape live: job="rova/rova-api"),
      # so job=~"opshub/.+" is the product split that Adaptive Metrics keeps.
      # Empty until opshub prod serves a request, so no_data_state = OK keeps
      # it silent before the launch.
      expr      = "sum(rate(http_server_duration_milliseconds_count{status_class=\"5xx\", job=~\"opshub/.+\", deployment_environment_name=\"prod\"}[5m])) / (sum(rate(http_server_duration_milliseconds_count{job=~\"opshub/.+\", deployment_environment_name=\"prod\"}[5m])) > 0)"
      op        = "gt"
      threshold = 0.05
      for       = "10m"
      no_data   = "OK"
      product   = "opshub"
      severity  = "critical"
      summary   = "opshub prod: more than 5% of API requests returned 5xx for 10 minutes. Check the API logs and the pg-opshub dependency first."
    }
    restart_loop = {
      name = "opshub-prod-container-restart-loop"
      # CrashLoopBackOff is the other, shared prod rule; this one also catches
      # a container that keeps restarting but never sits long enough in
      # CrashLoopBackOff to be counted (OOMKill loops that start, die and
      # restart). A deploy replaces the pod (counter resets), so a rollout
      # cannot trip it.
      expr      = "max by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total{namespace=\"opshub-prod\"}[15m]))"
      op        = "gt"
      threshold = 3
      for       = "5m"
      no_data   = "OK"
      product   = "opshub"
      severity  = "warning"
      summary   = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) restarted more than 3 times in 15 minutes."
    }
    pg_backup_age = {
      name = "opshub-pg-backup-too-old"
      # Same metric families and zero-filtering as the pg-rova rule
      # (onprem-data-p0.tf): the in-tree cnpg_collector_* family exists with
      # 0 when the barman-cloud plugin path is used, so zeros are dropped
      # BEFORE max (a 0 means "never", not 1970).
      #
      # DATA-EXISTS GATE (the absent-target rule): the second `or` branch
      # exists only while the cluster's exporter does. Before pg-opshub
      # exists the whole expression is empty → no_data_state = OK → silent.
      # Once it exists with no usable backup metric, the branch evaluates to
      # 1e9 (well over 26 h) and pages: "cluster is up, restores have no
      # source" is exactly what someone must act on.
      expr      = "time() - max by (cnpg_cluster) ({__name__=~\"cnpg_collector_last_available_backup_timestamp|barman_cloud_cloudnative_pg_io_last_available_backup_timestamp\", cnpg_cluster=\"pg-opshub\"} > 0) or max by (cnpg_cluster) (cnpg_collector_up{cnpg_cluster=\"pg-opshub\"}) * 0 + 1e9"
      op        = "gt"
      threshold = 26 * 3600
      for       = "15m"
      no_data   = "OK"
      product   = "opshub"
      severity  = "critical"
      summary   = "No successful pg-opshub base backup for over 26 hours (or the cluster reports and has no backup metric at all). WAL archiving alone cannot restore; check the ScheduledBackup and the R2 token."
    }
  }
}

resource "grafana_rule_group" "opshub_prod_app" {
  name             = "opshub (prod app)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.opshub_prod_app_rules
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
