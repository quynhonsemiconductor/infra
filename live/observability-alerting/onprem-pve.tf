# =============================================================================
# The Proxmox host's own metrics — the PVE 9 OpenTelemetry metric server that
# gitops#151 publishes on `alloy-otlp-host` and gitops#153 allowlists.
#
# GATED like the rest of the on-prem set (`onprem_alerts_enabled`, onprem-k3s.tf,
# default true): the series only exist once the host's metric server pushes.
#
# METRIC SOURCE: `service.name=proxmox-ve` on the cluster's Alloy OTLP receiver,
# Prometheus-exported with `job="proxmox-ve"`. Labels verified live in Grafana
# (2026-11-03) on the merged allowlist: `node` on the node family, `storage` on
# every store the host reports, `vmid`/`name`/`type` on the
# guest family. The fallback `job` label is what the exporter maps service.name
# to; every rule below selects by the PVE-specific label instead, so it cannot
# match a k3s metric.
#
# NOT here: node CPU/memory saturation (node-exporter already owns the k3s
# VM's view; the host's own pressure is a dashboard concern, not a page), and
# any per-disk `blockstat` series (dropped by the gitops allowlist — they were
# ~750 of the 843 series for no alerting value).
# =============================================================================

# HOST UP — absence IS the signal: the metric server is disabled, the API token
# path broke, or the Alloy door is closed. `absent_over_time` turns absence
# into data, so no_data_state is OK (empty = the metric is present = healthy).
resource "grafana_rule_group" "onprem_pve_host" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (pve — host)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    # absent_over_time turns absence into DATA (1), so an empty evaluation means
    # the series is present and healthy: OK. Alerting here would page on every
    # normal evaluation.
    name           = "pve-metrics-absent"
    condition      = "B"
    for            = "1m"
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
        # The window IS the requirement (absent for more than 10 minutes); `for`
        # adds one evaluation so a single missing push does not page.
        # ONE PVE node feeds this metric today; a second node gets its own rule
        # (or a node matcher) rather than changing what this one means. The
        # matcher pins the source to the PVE exporter (job = service.name) and
        # deliberately names no host — Tier 1 in a public repo.
        expr          = "absent_over_time(proxmox_node_uptime_seconds{job=\"proxmox-ve\"}[10m])"
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
      summary = "No proxmox_node_uptime_seconds for 10 minutes — the host's OpenTelemetry metric server stopped pushing or the Alloy OTLP door is closed. Every PVE series this estate alerts on is gone."
    }
  }
}

# STORAGE CAPACITY — the SAME 80/90 tiers as the k3s filesystem rules
# (onprem-k3s.tf; the server-setup runbook's host tiers), so host storage and
# the VM filesystem page at the same levels instead of a second scale. Per
# store: every store the host reports is watched. A store reporting total=0
# (inactive/misconfigured) is skipped instead of dividing by zero into +Inf.
resource "grafana_rule_group" "onprem_pve_storage" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (pve — storage)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  rule {
    name           = "pve-storage-over-80-percent"
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
        # `on(...)`: the ratio is the same vector's labels, joined explicitly on
        # the three labels PVE sets. The `and` keeps a zero-total store out.
        expr       = "proxmox_storage_used_bytes / on(job, node, storage) proxmox_storage_total_bytes and on(job, node, storage) (proxmox_storage_total_bytes > 0)"
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
      summary = "Storage {{ $labels.storage }} on {{ $labels.node }} is over 80% used (§12 host tiers). Free space or grow the pool before the 90% critical fires."
    }
  }

  rule {
    name           = "pve-storage-over-90-percent"
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
        expr       = "proxmox_storage_used_bytes / on(job, node, storage) proxmox_storage_total_bytes and on(job, node, storage) (proxmox_storage_total_bytes > 0)"
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
      summary = "Storage {{ $labels.storage }} on {{ $labels.node }} is over 90% used (§12 host tiers). At 100% the store stops accepting writes and the VMs on it fail."
    }
  }
}

# GUEST DOWN — the three estate VMs by name (template 9000 is excluded by the
# vmid matcher, so its flat uptime cannot page): either the uptime series is
# absent (VM stopped / guest agent gone) or it stopped increasing (wedged).
# The `changes` case needs 5 minutes of a flat gauge, which a running qemu
# cannot produce (uptime moves every scrape); the absence case uses `for`.
resource "grafana_rule_group" "onprem_pve_guests" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (pve — guests)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    # Both branches turn the failure into DATA, never into an empty result:
    # absent() = 1, and `== bool 0` turns a flat series into 1 (a plain `== 0`
    # would filter the 0 away and the `gt 0` threshold could never fire). An
    # empty evaluation is therefore the healthy case: OK, not Alerting.
    name           = "pve-vm-down"
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
        # `absent` on an equality matcher keeps `vmid` (and `name` only when the
        # series existed before) in the result, so the summary can name the VM.
        expr = join(" or ", [
          "absent(proxmox_vm_uptime_seconds{vmid=\"100\"})",
          "absent(proxmox_vm_uptime_seconds{vmid=\"101\"})",
          "absent(proxmox_vm_uptime_seconds{vmid=\"102\"})",
          "changes(proxmox_vm_uptime_seconds{vmid=~\"100|101|102\"}[5m]) == bool 0",
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
      summary = "VM {{ $labels.vmid }} ({{ $labels.name }}) on {{ $labels.node }} is down: its uptime series is absent or has been flat for 10 minutes. The estate's k3s node, AI node and VLSI node all live on this host."
    }
  }
}
