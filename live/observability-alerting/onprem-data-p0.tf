# =============================================================================
# P0 data-safety alerts for the on-prem prod data plane (audit G-06, PLAN
# 2026-11-02). All five read series that gitops platform/alloy keeps in its
# allowlists; each metric name was proven in Grafana before this merged (see the
# PR body). Gated like the rest of the on-prem set by `onprem_alerts_enabled`.
#
# no_data_state is per rule and deliberate:
#   Alerting  the SIGNAL is "this thing happened recently" (a backup, a dump, a
#             redis_up of 1). If the series disappears the evidence disappears
#             with it, so silence would be the wrong answer.
#   OK        the series only exists while there is something wrong (failed
#             Jobs) or the metric set is open-ended (PVCs).
# =============================================================================
locals {
  onprem_p0_rules = {
    pg_rova_backup_age = {
      name = "k3s-pg-rova-backup-too-old"
      # The nightly base backup is 19:00 UTC. 26 h = one missed night plus slack.
      # `or`: pg-rova backs up through the barman-cloud plugin; the instance
      # exporter may publish the in-tree or the plugin prefix.
      expr      = "time() - max by (cnpg_cluster) (cnpg_collector_last_available_backup_timestamp{cnpg_cluster=\"pg-rova\"} or barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{cnpg_cluster=\"pg-rova\"})"
      op        = "gt"
      threshold = 26 * 3600
      for       = "15m"
      no_data   = "Alerting"
      summary   = "No successful pg-rova base backup for over 26 hours (or the backup metric is missing). WAL archiving alone cannot restore; check the ScheduledBackup and the R2 token."
    }
    pg_rova_dump_age = {
      name      = "k3s-pg-rova-dump-too-old"
      expr      = "time() - max(kube_cronjob_status_last_successful_time{namespace=\"data-prod\", cronjob=\"pg-rova-dump\"})"
      op        = "gt"
      threshold = 26 * 3600
      for       = "15m"
      no_data   = "Alerting"
      summary   = "The pg-rova-dump CronJob has not succeeded for over 26 hours (or kube-state-metrics has no record of it). The locked nightly dump is the immutable restore source."
    }
    failed_jobs = {
      name      = "k3s-job-failed"
      expr      = "max by (namespace, job_name) (kube_job_failed{condition=\"true\", namespace=~\"data-prod|rova-prod|restore-test\"})"
      op        = "gt"
      threshold = 0
      for       = "5m"
      no_data   = "OK"
      summary   = "Job {{ $labels.namespace }}/{{ $labels.job_name }} failed (migrator PreSync, role-timeouts, restore test or dump)."
    }
    valkey_down = {
      name      = "k3s-valkey-prod-down"
      expr      = "min by (namespace, pod) (redis_up{namespace=\"data-prod\"})"
      op        = "lt"
      threshold = 1
      for       = "5m"
      no_data   = "Alerting"
      summary   = "valkey-rova exporter reports redis_up below 1 (or is not scraped) for 5 minutes. rova rate limits and security controls depend on it."
    }
    pvc_usage = {
      name      = "k3s-pvc-over-80-percent"
      expr      = "max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes)"
      op        = "gt"
      threshold = 0.8
      for       = "15m"
      no_data   = "OK"
      summary   = "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is over 80% full."
    }
  }
}

resource "grafana_rule_group" "onprem_data_p0" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (data safety — P0)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.onprem_p0_rules
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
          from = 300
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
        product  = "rova"
        env      = "production"
        severity = "critical"
      }

      annotations = {
        summary = r.value.summary
      }
    }
  }
}
