# =============================================================================
# P0 data-safety alerts for the on-prem prod data plane (audit G-06, PLAN
# 2026-11-02). All of them read series that gitops platform/alloy keeps in its
# allowlists. Gated like the rest of the on-prem set by `onprem_alerts_enabled`.
#
# STATUS: the metric names are NOT yet proven in Grafana by this PR. The SA
# proves each one (PromQL count) after gitops#98 (and the follow-up that adds
# kube_job_owner / kube_job_status_start_time) is synced; this stays a draft
# until then.
#
# no_data_state is per rule and deliberate:
#   Alerting  the SIGNAL is "this thing happened recently" (a backup, a redis_up
#             of 1). If the series disappears the evidence disappears with it,
#             so silence would be the wrong answer.
#   OK        the series only exists while something is wrong (failed Jobs),
#             the metric set is open-ended (PVCs), or the series legitimately
#             does not exist yet (the dump CronJob before its first success).
#
# Labels: env/severity route through the notification policy. Prod is
# env=production (Teams + email). Dev is env=development, severity warning, no
# `paging` label, so it is email only. product=rova only where the rule is
# about rova's own data; generic rules are product=platform.
# =============================================================================
locals {
  onprem_p0_rules = {
    pg_rova_backup_age = {
      name = "k3s-pg-rova-backup-too-old"
      # The nightly base backup is 19:00 UTC. 26 h = one missed night plus slack.
      # Two metric families can carry the same labels: the in-tree
      # cnpg_collector_* one (exists with value 0 when the in-tree barman path is
      # unused) and the barman-cloud plugin one. `or` would keep the first series
      # and silently drop the plugin's, so zero samples are filtered out BEFORE
      # max (a 0 is "never", not "1970").
      expr      = "time() - max by (cnpg_cluster) ({__name__=~\"cnpg_collector_last_available_backup_timestamp|barman_cloud_cloudnative_pg_io_last_available_backup_timestamp\", cnpg_cluster=\"pg-rova\"} > 0)"
      op        = "gt"
      threshold = 26 * 3600
      for       = "15m"
      no_data   = "Alerting"
      product   = "rova"
      env       = "production"
      severity  = "critical"
      summary   = "No successful pg-rova base backup for over 26 hours (or the backup metric is missing). WAL archiving alone cannot restore; check the ScheduledBackup and the R2 token."
    }
    pg_rova_dump_age = {
      name      = "k3s-pg-rova-dump-too-old"
      expr      = "time() - max(kube_cronjob_status_last_successful_time{namespace=\"data-prod\", cronjob=\"pg-rova-dump\"})"
      op        = "gt"
      threshold = 26 * 3600
      for       = "15m"
      # OK: the series does not exist until the CronJob's first success, and a
      # fresh cluster must not page before that. Once it exists, age keeps
      # growing and the rule fires. (A dead kube-state-metrics is a separate
      # signal: the pg-rova readiness rule and the node rules read it too.)
      no_data  = "OK"
      product  = "rova"
      env      = "production"
      severity = "critical"
      summary  = "The pg-rova-dump CronJob has not succeeded for over 26 hours. The locked nightly dump is the immutable restore source."
    }
    failed_jobs = {
      name = "k3s-job-failed"
      # The LATEST Job of each CronJob only (a later success clears the alert),
      # plus every Job that no CronJob owns (ArgoCD hook Jobs: migrator PreSync,
      # role-timeouts, restore test), which are replaced on the next sync.
      # Needs kube_job_owner and kube_job_status_start_time in the allowlist.
      expr      = "(max by (namespace, job_name) (kube_job_failed{condition=\"true\", namespace=~\"data-prod|rova-prod|restore-test\"}) and on (namespace, job_name) ((kube_job_status_start_time * on (namespace, job_name) group_left (owner_name) max by (namespace, job_name, owner_name) (kube_job_owner{owner_kind=\"CronJob\"})) == on (namespace, owner_name) group_left () max by (namespace, owner_name) (kube_job_status_start_time * on (namespace, job_name) group_left (owner_name) max by (namespace, job_name, owner_name) (kube_job_owner{owner_kind=\"CronJob\"})))) or (max by (namespace, job_name) (kube_job_failed{condition=\"true\", namespace=~\"data-prod|rova-prod|restore-test\"}) unless on (namespace, job_name) kube_job_owner{owner_kind=\"CronJob\"})"
      op        = "gt"
      threshold = 0
      for       = "5m"
      no_data   = "OK"
      product   = "platform"
      env       = "production"
      severity  = "critical"
      summary   = "Job {{ $labels.namespace }}/{{ $labels.job_name }} failed and has not been superseded by a successful run."
    }
    valkey_down = {
      name      = "k3s-valkey-prod-down"
      expr      = "min by (namespace, pod) (redis_up{namespace=\"data-prod\"})"
      op        = "lt"
      threshold = 1
      for       = "5m"
      no_data   = "Alerting"
      product   = "rova"
      env       = "production"
      severity  = "critical"
      summary   = "valkey-rova exporter reports redis_up below 1 (or is not scraped) for 5 minutes. rova rate limits and security controls depend on it."
    }
    pvc_usage_prod = {
      name      = "k3s-pvc-over-80-percent-prod"
      expr      = "max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{namespace=~\"data-prod|rova-prod\"} / kubelet_volume_stats_capacity_bytes{namespace=~\"data-prod|rova-prod\"})"
      op        = "gt"
      threshold = 0.8
      for       = "15m"
      no_data   = "OK"
      product   = "platform"
      env       = "production"
      severity  = "critical"
      summary   = "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is over 80% full."
    }
    pvc_usage_dev = {
      name      = "k3s-pvc-over-80-percent-dev"
      expr      = "max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{namespace=~\"data-dev|rova-dev|opshub-dev|kb-dev|ai|ai-lab|platform\"} / kubelet_volume_stats_capacity_bytes{namespace=~\"data-dev|rova-dev|opshub-dev|kb-dev|ai|ai-lab|platform\"})"
      op        = "gt"
      threshold = 0.8
      for       = "15m"
      no_data   = "OK"
      product   = "platform"
      env       = "development"
      severity  = "warning"
      summary   = "Dev PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is over 80% full."
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
        product  = r.value.product
        env      = r.value.env
        severity = r.value.severity
      }

      annotations = {
        summary = r.value.summary
      }
    }
  }
}
