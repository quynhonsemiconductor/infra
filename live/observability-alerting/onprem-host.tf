# =============================================================================
# Proxmox HOST risk signals (audit C-H1, 2026-11-04). Five rules for the one
# consumer NVMe (no PLP, no mirror) the whole estate runs on, its ZFS pools,
# host RAM and the PBS datastore on the HDD mirror.
#
# TWO SOURCES, both already on-premise:
#   * `pve_*` — the 5-minute textfile script installed by the Ansible role
#     `pve_monitoring` (infra/ansible/roles/pve_monitoring), scraped by a host
#     Alloy and pushed through the cluster's OTLP door. Label:
#     job="pve-host"; pool/device/datastore as noted.
#   * `proxmox_node_memory_memavailable_bytes` — PVE's own OpenTelemetry metric
#     server (gitops#151), job="proxmox-ve". Host RAM was already being
#     exported; it simply had no rule.
#
# GATED like the rest of the on-prem set (`onprem_alerts_enabled`). No-data is
# OK on every rule: the textfile push is being rolled out, and a host whose
# collector is not installed yet must not page. Once the role has run, the
# pve-metrics-absent rule below turns a dead collector into an alert.
# =============================================================================

resource "grafana_rule_group" "onprem_pve_risk" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (pve — disk and pool)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  # The pool is not ONLINE (DEGRADED/FAULTED/UNAVAIL/OFFLINE/REMOVED). On the
  # single-NVMe rpool this is the earliest warning that the disk is going; on
  # the HDD mirror it means one side is gone and there is no redundancy left.
  rule {
    name           = "pve-zpool-not-online"
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
        expr          = "min by (pool) (pve_zpool_health{job=\"pve-host\"})"
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
      summary = "ZFS pool {{ $labels.pool }} on pve01 is not ONLINE. The rpool is a single consumer NVMe; the backup pool is a two-disk mirror. Run `zpool status -x` on the host before the next backup window."
    }
  }

  # Pool fill. The same 80/90 tier as every other filesystem rule, but this
  # one also sees thin zvols: the guest zvols are CLOCKED at ~2.0 TB on a 2 TB
  # pool, so "3% used" today can become a full pool without any VM writing
  # much more than it already does.
  rule {
    name           = "pve-zpool-over-80-percent"
    condition      = "B"
    for            = "15m"
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
        expr          = "pve_zpool_allocated_bytes{job=\"pve-host\"} / pve_zpool_size_bytes{job=\"pve-host\"} and on(pool) (pve_zpool_size_bytes{job=\"pve-host\"} > 0)"
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
      summary = "ZFS pool {{ $labels.pool }} on pve01 is over 80% allocated. The zvols are thin-provisioned; free space or grow the pool before PBS and the VM snapshots need it."
    }
  }

  # NVMe wear, media errors or the controller's critical-warning flag. One
  # rule, because all three answer the same question ("replace this disk
  # before it takes the estate down") and the owner acts the same way.
  # `bool` turns each comparison into 0/1 so the three can be `or`-ed without
  # losing a 0-valued series; threshold > 0 catches any one of them.
  rule {
    name           = "pve-nvme-wear-or-errors"
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
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr = join(" or ", [
          "(pve_nvme_percentage_used{job=\"pve-host\"} > bool 80)",
          "(pve_nvme_media_errors{job=\"pve-host\"} > bool 0)",
          "(pve_nvme_critical_warning{job=\"pve-host\"} > bool 0)",
        ])
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
      product  = "platform"
      env      = "production"
      severity = "critical"
    }

    annotations = {
      summary = "NVMe {{ $labels.device }} on pve01 reports wear over 80%, a media error, or a critical SMART warning. This is the single disk the whole estate runs on (no PLP, no mirror): plan the replacement and confirm the PBS off-site copy before it fails."
    }
  }

  # Host RAM. VMs are assigned 56 GiB against 64 GiB with no swap; if the host
  # itself runs out, the OOM killer takes the largest QEMU process, which is
  # k3s-01 — all of prod. 2 GiB is the floor where PVE, PBS verify/GC and KSM
  # can still work; the 2026-11-04 measurement was 13.0 GiB available.
  rule {
    name           = "pve-host-memory-low"
    condition      = "B"
    for            = "10m"
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
        expr          = "proxmox_node_memory_memavailable_bytes{job=\"proxmox-ve\"} < 2 * 1024 * 1024 * 1024"
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
      product  = "platform"
      env      = "production"
      severity = "critical"
    }

    annotations = {
      summary = "pve01 has under 2 GiB RAM available for 10 minutes. The VMs are assigned 56 of 64 GiB with no swap; if the host OOMs, the kernel kills the largest guest — k3s-01, i.e. all of prod. Identify the guest that grew and stop or shrink it."
    }
  }

  # PBS datastore fill. This is the only off-host copy of the VMs today (on the
  # same chassis, but a separate HDD mirror); a full datastore stops the next
  # nightly base backup, which is the restore source.
  rule {
    name           = "pve-pbs-datastore-over-80-percent"
    condition      = "B"
    for            = "15m"
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
        expr          = "pve_pbs_datastore_used_bytes{job=\"pve-host\"} / pve_pbs_datastore_size_bytes{job=\"pve-host\"} and on(datastore) (pve_pbs_datastore_size_bytes{job=\"pve-host\"} > 0)"
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
      summary = "PBS datastore {{ $labels.datastore }} on pve01 is over 80% full. Prune or grow it before the next nightly base backup fails; this datastore is the VM restore source."
    }
  }
}

# COLLECTOR DEAD — the textfile script is installed by the Ansible role, so
# absence after that is a real failure, not "not rolled out yet". Same
# `absent_over_time` shape as pve-metrics-absent: the empty result is the
# healthy case (no_data OK); the alert fires on the synthesized 1.
resource "grafana_rule_group" "onprem_pve_textfile_absent" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (pve — host collector)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  rule {
    name           = "pve-host-metrics-absent"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "KeepLast"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 1800
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "absent_over_time(pve_zpool_health{job=\"pve-host\"}[30m])"
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
      product  = "platform"
      env      = "production"
      severity = "critical"
    }

    annotations = {
      summary = "No pve_zpool_health from pve01 for 30 minutes. The textfile timer, node-exporter or the host Alloy push has stopped, so every ZFS/NVMe/PBS signal above is blind. Check `systemctl status pve-metrics.timer prometheus-node-exporter alloy-pve` on the host."
    }
  }
}
