# =============================================================================
# VLSI / Coder — the ONE dashboard for the workspace platform (coverage audit
# 2026-11-07 §5).
#
# infra#464 added a VLSI/Coder ROW inside "Platform health" and the two alerts
# (Coder down, vlsi-ws quota). The audit read that as "no VLSI/Coder dashboard"
# because a row inside a platform-wide dashboard is not a surface anyone opens
# to answer a VLSI question. This is that surface: the same four signals the
# row carries, plus the vlsi-01 node the workspaces actually run on, so the
# owner's "is the GPU box healthy / who is using the quota" question is one
# page.
#
# SERIES: every panel reads a family that already reaches Mimir, no new scrape
# and no new series —
#   job="coder"         coderd scrape in gitops platform/alloy (allowlist:
#                       coderd_agents_up, coderd_provisionerd_jobs_current,
#                       coderd_license_active_users, coderd_license_limit_users,
#                       coderd_license_warnings, coderd_license_errors, up)
#
# FIXED IN ROUND 2 (SA, 2026-11-07): `job="coder"` carried ONLY `up` and
# `scrape_samples_scraped`, so every Coder panel was blank. Three faults, all
# fixed in gitops PR "fix(coder): actually export coderd metrics": the exporter
# was never enabled (no default for --prometheus-enable in 2.38.1), the coder
# ingress NetworkPolicy admitted nothing from Alloy on 2112, and two names in
# the allowlist do not exist (`coderd_agent_aggregator_workspace_count_total`,
# `coderd_license_user_count`). Workspaces are counted from `coderd_agents_up`;
# licence seat use is `coderd_license_active_users`.
#   kube_resourcequota  KSM allowlist (gitops platform/alloy)
#   job="node"          node-exporter, instance=<node name> (the chart's
#                       relabel maps __meta_kubernetes_pod_node_name to instance)
#   DCGM_FI_DEV_*       dcgm-exporter in gpu-monitoring (gitops#385)
#
# WHY instance="vlsi-01" AND NOT A NODE LABEL: the node-exporter targets carry
# no `node` label; the chart's relabel puts the node name in `instance`. The
# Platform health panels already read the same families without a node filter.
# =============================================================================

resource "grafana_dashboard" "vlsi_coder" {
  folder    = grafana_folder.dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "VLSI / Coder"
    uid           = "vlsi-coder"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-6h", to = "now" }
    refresh       = "1m"
    tags          = ["vlsi", "coder", "platform", "provisioned"]

    panels = [
      {
        id      = 1
        type    = "row"
        title   = "Coder control plane"
        gridPos = { h = 1, w = 24, x = 0, y = 0 }
      },
      {
        id          = 2
        title       = "Coder up"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 0, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", noValue = "no scrape", thresholds = { mode = "absolute", steps = [{ color = "red", value = null }, { color = "green", value = 1 }] } } }
        targets     = [{ expr = "min(up{job=\"coder\"})", refId = "A" }]
      },
      {
        id          = 3
        title       = "Workspace agents up"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 6, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", noValue = "none" } }
        targets     = [{ expr = "sum(coderd_agents_up)", refId = "A" }]
      },
      {
        id          = 4
        title       = "Workspaces"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 12, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", noValue = "none" } }
        targets     = [{ expr = "count(count by (workspace_name) (coderd_agents_up))", refId = "A" }]
      },
      {
        id          = 5
        title       = "Provisioner jobs running"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 18, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", noValue = "none" } }
        targets     = [{ expr = "sum(coderd_provisionerd_jobs_current)", refId = "A" }]
      },
      {
        id          = 6
        title       = "Licence seats — active / limit"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 0, y = 5 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", noValue = "none" } }
        targets = [
          { expr = "max(coderd_license_active_users)", legendFormat = "active", refId = "A" },
          { expr = "max(coderd_license_limit_users)", legendFormat = "limit", refId = "B" },
        ]
      },
      {
        id      = 7
        type    = "row"
        title   = "vlsi-ws quota"
        gridPos = { h = 1, w = 24, x = 0, y = 9 }
      },
      {
        id          = 8
        title       = "Quota used (worst resource)"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 6, y = 10 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit", max = 1, noValue = "no quota", thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "yellow", value = 0.85 }] } } }
        targets = [{
          expr  = "max(max by (resource) (kube_resourcequota{namespace=\"vlsi-ws\", type=\"used\"} / ignoring(type) kube_resourcequota{namespace=\"vlsi-ws\", type=\"hard\"}))"
          refId = "A"
        }]
      },
      {
        id          = 9
        title       = "Quota used per resource"
        type        = "timeseries"
        gridPos     = { h = 4, w = 18, x = 6, y = 14 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit", min = 0, max = 1, noValue = "no quota" } }
        targets = [{
          expr         = "max by (resource) (kube_resourcequota{namespace=\"vlsi-ws\", type=\"used\"} / ignoring(type) kube_resourcequota{namespace=\"vlsi-ws\", type=\"hard\"})"
          legendFormat = "{{resource}}"
          refId        = "A"
        }]
      },
      {
        id      = 10
        type    = "row"
        title   = "vlsi-01 node"
        gridPos = { h = 1, w = 24, x = 0, y = 18 }
      },
      {
        id          = 11
        title       = "CPU used %"
        type        = "timeseries"
        gridPos     = { h = 6, w = 8, x = 0, y = 19 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percent", min = 0, max = 100, noValue = "no node series" } }
        targets = [{
          expr         = "100 - avg by (instance) (rate(node_cpu_seconds_total{instance=\"vlsi-01\", mode=\"idle\"}[5m])) * 100"
          legendFormat = "{{instance}}"
          refId        = "A"
        }]
      },
      {
        id          = 12
        title       = "Memory used %"
        type        = "timeseries"
        gridPos     = { h = 6, w = 8, x = 8, y = 19 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percent", min = 0, max = 100, noValue = "no node series" } }
        targets = [{
          expr         = "100 * (1 - node_memory_MemAvailable_bytes{instance=\"vlsi-01\"} / node_memory_MemTotal_bytes{instance=\"vlsi-01\"})"
          legendFormat = "{{instance}}"
          refId        = "A"
        }]
      },
      {
        id          = 13
        title       = "Root filesystem used %"
        type        = "timeseries"
        gridPos     = { h = 6, w = 8, x = 16, y = 19 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percent", min = 0, max = 100, noValue = "no node series" } }
        targets = [{
          expr         = "100 * (1 - node_filesystem_avail_bytes{instance=\"vlsi-01\", mountpoint=\"/\", fstype!~\"tmpfs|overlay|squashfs|devtmpfs|nsfs\"} / node_filesystem_size_bytes{instance=\"vlsi-01\", mountpoint=\"/\", fstype!~\"tmpfs|overlay|squashfs|devtmpfs|nsfs\"})"
          legendFormat = "{{instance}}"
          refId        = "A"
        }]
      },
      {
        id      = 14
        type    = "row"
        title   = "GPU"
        gridPos = { h = 1, w = 24, x = 0, y = 25 }
      },
      {
        id          = 15
        title       = "GPU utilisation %"
        type        = "timeseries"
        gridPos     = { h = 6, w = 8, x = 0, y = 26 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percent", min = 0, max = 100, noValue = "no dcgm series" } }
        targets = [{
          expr         = "max by (gpu, modelName) (DCGM_FI_DEV_GPU_UTIL)"
          legendFormat = "GPU {{gpu}} {{modelName}}"
          refId        = "A"
        }]
      },
      {
        id          = 16
        title       = "GPU framebuffer used (MiB)"
        type        = "timeseries"
        gridPos     = { h = 6, w = 8, x = 8, y = 26 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", noValue = "no dcgm series" } }
        targets = [{
          expr         = "max by (gpu) (DCGM_FI_DEV_FB_USED)"
          legendFormat = "GPU {{gpu}}"
          refId        = "A"
        }]
      },
      {
        id          = 17
        title       = "GPU temperature (°C)"
        type        = "timeseries"
        gridPos     = { h = 6, w = 8, x = 16, y = 26 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "celsius", noValue = "no dcgm series", thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "yellow", value = 80 }] } } }
        targets = [{
          expr         = "max by (gpu) (DCGM_FI_DEV_GPU_TEMP)"
          legendFormat = "GPU {{gpu}}"
          refId        = "A"
        }]
      },
    ]
  })
}
