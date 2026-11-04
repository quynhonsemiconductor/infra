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
# GATED TWICE: `onprem_alerts_enabled` (the rest of the on-prem set) AND
# `pve_host_metrics_live` below, which stays false until the owner has run the
# Ansible role. Without the second gate, pve-host-metrics-absent would fire
# immediately on merge — the collector does not exist yet, and absence is
# exactly what that rule detects. No-data is OK on every presence rule.
# =============================================================================

# ROLLOUT GATE: the textfile producer only exists after the owner runs the
# Ansible role. `pve-host-metrics-absent` uses absent_over_time, which would
# otherwise fire from the moment this merges (absence is exactly the state
# before the play runs). Flip `pve_host_metrics_live` in the PR that records
# the play; until then every rule in this file is culled.
variable "pve_host_metrics_live" {
  description = "Arms the pve01 host rules (onprem-host.tf). Flip to true AFTER `ansible-playbook pve-host.yml --tags pve_monitoring` has installed the textfile producer; false = all host rules culled."
  type        = bool
  default     = false
}

locals {
  pve_host_live = local.onprem_live && var.pve_host_metrics_live
}

resource "grafana_rule_group" "onprem_pve_risk" {
  count            = local.pve_host_live ? 1 : 0
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

  # EXPECTED POOLS. `zpool list` simply omits a pool that was destroyed or
  # failed to import, so the not-ONLINE rule above goes NoData and reads
  # healthy. `absent()` turns each missing expected pool into a 1. The pool
  # names are the host's two real pools (rpool = the NVMe; backup = the 2x4 TB
  # HDD mirror); a third pool is a change to this rule, deliberately.
  rule {
    name           = "pve-zpool-expected-missing"
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
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr = join(" or ", [
          "absent(pve_zpool_health{job=\"pve-host\",pool=\"rpool\"})",
          "absent(pve_zpool_health{job=\"pve-host\",pool=\"backup\"})",
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
      summary = "An expected ZFS pool (rpool or backup) is missing from pve01's zpool list. It failed to import or was destroyed — the VMs or the backup mirror are no longer on a pool the host sees. Run `zpool import` / `zpool status` on the host."
    }
  }

  # NVMe health is THREE rules, not one `or`: all three branches carry the same
  # `device` label set, and PromQL `or` returns only the left-hand series when
  # label sets match — so a media error would have been hidden behind a healthy
  # wear value. Separate rules keep each condition independently visible.
  rule {
    name           = "pve-nvme-wear-over-80"
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
        expr          = "pve_nvme_percentage_used{job=\"pve-host\"} > 80"
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
      severity = "warning"
    }

    annotations = {
      summary = "NVMe {{ $labels.device }} on pve01 is at {{ $value }}% rated wear. This is the single no-PLP disk the whole estate runs on: plan the replacement before 100%, and confirm the PBS off-site copy."
    }
  }

  rule {
    name           = "pve-nvme-media-errors"
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
        expr          = "pve_nvme_media_errors{job=\"pve-host\"} > 0"
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
      summary = "NVMe {{ $labels.device }} on pve01 reports {{ $value }} uncorrected media error(s). The disk has lost data internally; confirm the PBS copy and replace it."
    }
  }

  rule {
    name           = "pve-nvme-critical-warning"
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
        expr          = "pve_nvme_critical_warning{job=\"pve-host\"} > 0"
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
      summary = "NVMe {{ $labels.device }} on pve01 raised a SMART critical warning ({{ $value }}). Replace the disk; this is the only copy of the running estate."
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

# COLLECTOR DEAD OR STALE — the textfile script is installed by the Ansible
# role, so absence after that is a real failure, not "not rolled out yet".
# `absent_over_time` turns absence into data (empty result = healthy, no_data
# OK). The second rule catches the harder case a textfile collector cannot see
# by itself: the file is present but frozen, so every gauge reads a stale value.
resource "grafana_rule_group" "onprem_pve_textfile_absent" {
  count            = local.pve_host_live ? 1 : 0
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

  # STALE, not absent: the file (and its series) still exist, but the timer or
  # script stopped rewriting it. node-exporter cannot tell a fresh textfile
  # from a week-old one, so the script stamps the epoch of its last COMPLETED
  # run. 15 min = three missed 5-minute ticks (one lost tick is tolerated).
  rule {
    name           = "pve-metrics-stale"
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
        expr          = "time() - pve_metrics_last_success_timestamp_seconds{job=\"pve-host\"} > 900"
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
      summary = "The pve01 textfile snapshot has not been rewritten for over 15 minutes (last successful run {{ $value }}s ago). The series are still present but STALE — every ZFS/NVMe/PBS value is frozen. Check `systemctl status pve-metrics.timer` and `journalctl -u pve-metrics` on the host."
    }
  }
}
