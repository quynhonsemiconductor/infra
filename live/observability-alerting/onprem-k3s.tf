# =============================================================================
# On-prem (k3s) alert rules — ONPREM-PLAN §12's "On-prem alert" table.
#
# DORMANT BY DESIGN, and honestly so: these expressions read series that only
# exist once the k3s node joins with the Alloy agent — today they return no
# data. Rules whose SIGNAL is absence (node down) use no_data_state =
# "Alerting" (a vanished series IS the alert); presence rules (fs capacity,
# CNPG) use no_data_state = "OK" so a not-yet-built cluster stays quiet.
# They arm at the cutover without a flip: the series appear, the rules start
# judging. env=production on each rule routes through the notification
# policy's Teams child; product=platform keeps the grouping consistent with
# the rest of the folder.
#
# METRIC NAMES: node_* names are the node_exporter collectors the gitops
# agent allowlist keeps (platform/alloy/agent.alloy — this repo's sibling
# PR); cnpg_*/pg_stat_archiver* are CNPG's default instance-exporter set.
# Both get verified against the live scrape at the cutover rehearsal
# (Stage D2's checklist) — the allowlist above keeps exactly these families.
#
# NOT here, deliberately: backup failed/missed (Healthchecks.io owns the
# batch-job pings — dump, restore test, Azure copy), cert expiry (the weekly
# expiry-check Action covers Entra/Cloudflare/GitHub credentials; CNPG
# server certs renew automatically ~90 days), /readyz failing (Synthetic
# Monitoring), tunnel down (covered by the readyz check + node down).
# =============================================================================

# NODE DOWN — absence IS the signal: the node-exporter `up` series vanishing
# (agent dead, node hung) must fire, so no_data_state = "Alerting".
resource "grafana_rule_group" "onprem_node_down" {
  count            = 1
  name             = "onprem (k3s — node)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-node-exporter-down-or-absent"
    condition      = "B"
    for            = "5m"
    no_data_state  = "Alerting"
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
        expr          = "up{job=\"node\"}"
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
      product  = "platform"
      env      = "production"
      severity = "critical"
    }

    annotations = {
      summary = "The k3s node's node-exporter is down or absent — the node is hung, rebooting or the Alloy agent is dead. §12 node-down."
    }
  }
}

# ── Presence rules: quiet until the cluster exists, then armed ──────────────
resource "grafana_rule_group" "onprem_disk_zfs" {
  count            = 1
  name             = "onprem (k3s — disk and ZFS)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  # §12: "VM filesystem < 20% free". Fires per mountpoint that crosses 80 %
  # used and stays there 10 m. no_data_state = OK: the cluster not existing
  # is not an alert; the node-down rule owns absence.
  rule {
    name           = "k3s-filesystem-over-80-percent"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "KeepLast"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr       = "1 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\"})"
        instant    = true
        range      = false
        intervalMs = 1000
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
              params = [0.8]
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
      summary = "Filesystem {{ $labels.mountpoint }} on the k3s node is over 80% used (§12: VM filesystem < 20% free)."
    }
  }

  # ZFS pool over 80% — same ratio, on the pool series the allowlist keeps.
  rule {
    name           = "k3s-zfs-pool-over-80-percent"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "KeepLast"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr       = "node_zfs_zpool_used_bytes / node_zfs_zpool_size_bytes"
        instant    = true
        range      = false
        intervalMs = 1000
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
              params = [0.8]
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
      summary = "ZFS pool {{ $labels.pool }} is over 80% used (§12: ZFS pool > 80%)."
    }
  }
}

resource "grafana_rule_group" "onprem_cnpg" {
  count            = 1
  name             = "onprem (k3s — CNPG)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  # WAL archiving is the PITR backbone (RPO = minutes): an archiver failure
  # breaks point-in-time recovery silently if only the dump ping is watched.
  rule {
    name           = "k3s-cnpg-wal-archiver-failing"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "KeepLast"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr       = "increase(cnpg_pg_stat_archiver_failed_count[10m])"
        instant    = true
        range      = false
        intervalMs = 1000
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
      product  = "platform"
      env      = "production"
      severity = "critical"
    }

    annotations = {
      summary = "CNPG WAL archiver recorded failures in the last 10 m (§12: WAL archiving failing = PITR broken)."
    }
  }

  # Replication lag — fires when a replica exists and falls behind; with the
  # day-1 single-instance clusters the series is absent (no_data = OK).
  rule {
    name           = "k3s-cnpg-replication-lag"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "KeepLast"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr       = "cnpg_pg_replication_lag"
        instant    = true
        range      = false
        intervalMs = 1000
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
              params = [10]
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
      severity = "warning"
    }

    annotations = {
      summary = "CNPG replication lag over 10 units on {{ $labels.namespace }}/{{ $labels.cluster }} (§12: CNPG replication failure)."
    }
  }
}
