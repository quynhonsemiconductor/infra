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
#             the database/cluster does not exist yet (CNPG size, before a
#             launch), or the series legitimately does not exist yet (the dump
#             CronJob before its first success).
#
# The two PVC rules were REMOVED (2026-11-04): hostPath PVs emit no
# kubelet_volume_stats_*, so they could never fire for the prod CNPG clusters.
# db_storage_free below watches the filesystem those PVs live on instead.
#
# Labels: env/severity route through the notification policy. Prod is
# env=prod (Teams + email). Dev is env=dev, severity warning, no
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
      env       = "prod"
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
      env      = "prod"
      severity = "critical"
      summary  = "The pg-rova-dump CronJob has not succeeded for over 26 hours. The locked nightly dump is the immutable restore source."
    }
    failed_jobs = {
      name = "k3s-job-failed"
      # The LATEST Job of each CronJob only (a later success clears the alert),
      # plus every Job that no CronJob owns (ArgoCD hook Jobs: migrator PreSync
      # in the product namespaces, role-timeouts and the restore test in
      # restore-test), which are replaced on the next sync.
      # Needs kube_job_owner and kube_job_status_start_time in the allowlist.
      expr      = "(max by (namespace, job_name) (kube_job_failed{condition=\"true\", namespace=~\"data-prod|rova-prod|opshub-prod|kb-prod|restore-test\"}) and on (namespace, job_name) ((kube_job_status_start_time * on (namespace, job_name) group_left (owner_name) max by (namespace, job_name, owner_name) (kube_job_owner{owner_kind=\"CronJob\"})) == on (namespace, owner_name) group_left () max by (namespace, owner_name) (kube_job_status_start_time * on (namespace, job_name) group_left (owner_name) max by (namespace, job_name, owner_name) (kube_job_owner{owner_kind=\"CronJob\"})))) or (max by (namespace, job_name) (kube_job_failed{condition=\"true\", namespace=~\"data-prod|rova-prod|opshub-prod|kb-prod|restore-test\"}) unless on (namespace, job_name) kube_job_owner{owner_kind=\"CronJob\"})"
      op        = "gt"
      threshold = 0
      for       = "5m"
      no_data   = "OK"
      product   = "platform"
      env       = "prod"
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
      # platform, not rova: the expression covers all three prod valkeys
      # (rova, opshub, kb). The summary names the pod via the label.
      product  = "platform"
      env      = "prod"
      severity = "critical"
      summary  = "Valkey {{ $labels.namespace }}/{{ $labels.pod }} reports redis_up below 1 (or is not scraped) for 5 minutes. Every product's rate limits and security controls depend on it."
    }
    # DB DISK, measured on the FILESYSTEM that holds the data, not on the PVC.
    # The two kubelet_volume_stats PVC rules were blind: local-path-retain PVs
    # are hostPath on the k3s node (local-path-retain has no
    # defaultVolumeType=local annotation), and hostPath volumes emit no
    # kubelet_volume_stats_* — pg-rova/pg-opshub had zero series after the
    # 2026-11-03 move, and no_data_state=OK read that as healthy. The generic
    # k3s-filesystem rules cover every mount at 80/90%, but this is the
    # DB-specific floor the data plane needs: the storage zvol is 1.2 TB and
    # 100 GiB free is ~8%, where PostgreSQL's WAL and a base backup can still
    # consume the rest in a day. Absolute, so it does not shift with pool size.
    db_storage_free = {
      name = "k3s-db-storage-free-below-100g"
      # Raw free bytes here; the 100 GiB floor is the rule's threshold below.
      # A pre-filtered expression (the old `< 100 * 1024^3`) returns nothing
      # while the disk is healthy, which the 7-day data guard reads as a
      # broken selector.
      expr      = "node_filesystem_avail_bytes{mountpoint=\"/var/lib/rancher/k3s/storage\", fstype!~\"tmpfs|overlay|squashfs\"}"
      op        = "lt"
      threshold = 100 * 1024 * 1024 * 1024
      for       = "15m"
      no_data   = "OK"
      product   = "platform"
      env       = "prod"
      severity  = "critical"
      summary   = "Less than 100 GiB free on the k3s data disk (/var/lib/rancher/k3s/storage) — every CNPG cluster, its WAL and its base backups live there. Free space or grow the disk before a backup fills it."
    }
    # CNPG DATABASE SIZE — per database, the growth signal the filesystem rule
    # cannot give (a single database can outgrow its usefulness long before the
    # disk fills). 15 GiB is the review line, not a hard limit: pg-rova and
    # pg-opshub are far below it today. Warning only; the disk rule is the
    # critical path. A cluster that has no series (pg-kb before launch) is
    # no-data/OK.
    cnpg_database_size = {
      name      = "k3s-cnpg-database-over-15g"
      expr      = "max by (cnpg_cluster, datname) (cnpg_pg_database_size_bytes{namespace=\"data-prod\"})"
      op        = "gt"
      threshold = 15 * 1024 * 1024 * 1024
      for       = "1h"
      no_data   = "OK"
      product   = "platform"
      env       = "prod"
      severity  = "warning"
      summary   = "Database {{ $labels.datname }} on {{ $labels.cnpg_cluster }} is over 15 GiB. Check what grew (table sizes, retained operational rows) before the nightly base backup and WAL copy have to carry it to R2."
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
