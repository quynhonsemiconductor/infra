# =============================================================================
# On-prem (k3s) alert rules — ONPREM-PLAN §12's "On-prem alert" table.
#
# GATED: every group is `count = var.onprem_alerts_enabled ? 1 : 0` (default
# false) — with the series absent pre-cutover, an ungated node-down rule
# would page Teams from the moment the PR merges. Arming = a one-line PR at
# the cutover; the rules themselves are written for the live estate and need
# no further change.
#
# DORMANT-SHAPE: rules whose SIGNAL is absence (node down) use no_data_state
# = "Alerting" (a vanished series IS the alert); presence rules use
# no_data_state = "OK". All carry env=production (Teams child) +
# product=platform, and exec_err_state = KeepLast (a Loki/pipeline fault
# must not page — same decision as the fail-open rules).
#
# METRIC NAMES: node_* are the node_exporter collectors the gitops agent
# allowlist keeps (platform/alloy/agent.alloy; the node scrape is labelled
# job="node" there); cnpg_*/pg_stat_archiver* are CNPG's default
# instance-exporter set. Both verified against the live scrape at the
# cutover rehearsal (Stage D2 checklist).
#
# NOT here, deliberately: backup failed/missed (Healthchecks.io owns the
# batch-job pings), cert expiry (weekly expiry-check Action; CNPG server
# certs auto-renew ~90 d), /readyz failing and tunnel down (Synthetic
# Monitoring's readyz check + the node-down rule), ZFS pool capacity/health
# (the pools live on the pve01 HOST, not in the k3s VM this scrapes — the
# host-metrics design is in the server-setup runbook, with the 80/90 tiers
# documented there for the host textfile collector).
# =============================================================================

variable "onprem_alerts_enabled" {
  description = "Arms the on-prem rule groups. Flip via a one-line PR at the cutover (Stage D2 rehearsal arms it in rehearsal). false = the groups are culled and the plan shows nothing."
  type        = bool
  default     = true
}

locals {
  onprem_live = var.onprem_alerts_enabled
}

# NODE DOWN — absence IS the signal: the node-exporter `up` series vanishing
# (agent dead, node hung) must fire, so no_data_state = "Alerting".
resource "grafana_rule_group" "onprem_node_down" {
  count            = local.onprem_live ? 1 : 0
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

# ── Filesystem capacity: warning at 80 %, critical at 90 % ──────────────────
# fstype and mountpoint exclusions are the standard noise cut: pseudo-
# filesystems (tmpfs/overlay/squashfs/devtmpfs/nsfs) and kubelet/runtime
# ephemeral mounts are unbounded in count and meaningless in capacity.
resource "grafana_rule_group" "onprem_fs" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (k3s — filesystem)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

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
        expr       = "1 - (node_filesystem_avail_bytes{fstype!~\"squashfs|devtmpfs|nsfs|tmpfs|overlay\",mountpoint!~\"/run(/.*)?|/var/lib/kubelet(/.*)?\"} / node_filesystem_size_bytes{fstype!~\"squashfs|devtmpfs|nsfs|tmpfs|overlay\",mountpoint!~\"/run(/.*)?|/var/lib/kubelet(/.*)?\"})"
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
      severity = "warning"
    }

    annotations = {
      summary = "Filesystem {{ $labels.mountpoint }} on the k3s node is over 80% used (§12: VM filesystem < 20% free)."
    }
  }

  rule {
    name           = "k3s-filesystem-over-90-percent"
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
        expr       = "1 - (node_filesystem_avail_bytes{fstype!~\"squashfs|devtmpfs|nsfs|tmpfs|overlay\",mountpoint!~\"/run(/.*)?|/var/lib/kubelet(/.*)?\"} / node_filesystem_size_bytes{fstype!~\"squashfs|devtmpfs|nsfs|tmpfs|overlay\",mountpoint!~\"/run(/.*)?|/var/lib/kubelet(/.*)?\"})"
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
              params = [0.9]
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
      summary = "Filesystem {{ $labels.mountpoint }} on the k3s node is over 90% used — data-loss territory; act now (§12)."
    }
  }
}

# ── CNPG: WAL archiving + replication lag ───────────────────────────────────
resource "grafana_rule_group" "onprem_cnpg" {
  count            = local.onprem_live ? 1 : 0
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
      summary = "CNPG replication lag over 10 units on {{ $labels.namespace }}/{{ $labels.cnpg_cluster }} (§12: CNPG replication failure)."
    }
  }
}
