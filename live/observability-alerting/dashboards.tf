# =============================================================================
# Two dashboards, KISS (observability audit 2026-11-06 §1).
#
# The audit's recommendation: do NOT activate the Kubernetes Monitoring app on
# the free tier (its views need series the trimmed KSM allowlist drops and it
# adds ruler series), and do not import six integration dashboards. Build two
# that reuse the alert expressions already in this stack, so they cost no extra
# series:
#
#   Products (RED)   request rate, 5xx ratio, p95 latency and the status-class
#                    split, ONE line per job+env. Replaces the broken panels in
#                    system-overview and both dead rova AWS-era dashboards.
#   Platform health  nodes/filesystems, PVE/PBS, CNPG/backups, Valkey,
#                    ArgoCD/ESO/cert, tunnel and the synthetic uptime.
# =============================================================================

resource "grafana_dashboard" "products_red" {
  folder    = grafana_folder.dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "Products (RED)"
    uid           = "products-red"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-6h", to = "now" }
    refresh       = "1m"
    tags          = ["products", "red", "provisioned"]

    # $product and $env are multi-value queries over the app metric family.
    # `job` is `<product>/<service>`; `deployment_environment_name` is
    # `dev`/`prod` on the datapoints (gitops env-label processor).
    templating = {
      list = [
        {
          name       = "product"
          type       = "query"
          label      = "product (job)"
          datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
          query      = { query = "label_values(http_server_duration_milliseconds_count, job)", refId = "StandardVariableQuery" }
          includeAll = true
          multi      = true
          allValue   = ".+"
          current    = { selected = true, text = ["All"], value = ["$__all"] }
        },
        {
          name       = "env"
          type       = "query"
          label      = "environment"
          datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
          query      = { query = "label_values(http_server_duration_milliseconds_count, deployment_environment_name)", refId = "StandardVariableQuery" }
          includeAll = true
          multi      = true
          allValue   = ".+"
          current    = { selected = true, text = ["All"], value = ["$__all"] }
        },
      ]
    }

    panels = [
      {
        id         = 1
        title      = "Request rate (req/s)"
        type       = "timeseries"
        gridPos    = { h = 8, w = 12, x = 0, y = 0 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [{
          expr         = "sum by (job, deployment_environment_name) (rate(http_server_duration_milliseconds_count{job=~\"$product\", deployment_environment_name=~\"$env\"}[5m]))"
          legendFormat = "{{job}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id          = 2
        title       = "5xx ratio"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 12, y = 0 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit", min = 0 } }
        # Same shape as the 5xx rules: a grouped numerator that vanishes when a
        # product has zero errors is re-seeded from the all-status series so the
        # line reads 0 instead of disappearing.
        targets = [{
          expr = join("", [
            "(",
            "sum by (job, deployment_environment_name) (rate(http_server_duration_milliseconds_count{status_class=\"5xx\", job=~\"$product\", deployment_environment_name=~\"$env\"}[5m]))",
            " or ",
            "sum by (job, deployment_environment_name) (rate(http_server_duration_milliseconds_count{job=~\"$product\", deployment_environment_name=~\"$env\"}[5m])) * 0",
            ") / ",
            "sum by (job, deployment_environment_name) (rate(http_server_duration_milliseconds_count{job=~\"$product\", deployment_environment_name=~\"$env\"}[5m]))",
          ])
          legendFormat = "{{job}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id          = 3
        title       = "p95 latency"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 0, y = 8 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "ms" } }
        targets = [{
          expr         = "histogram_quantile(0.95, sum by (le, job, deployment_environment_name) (rate(http_server_duration_milliseconds_bucket{job=~\"$product\", deployment_environment_name=~\"$env\"}[5m])))"
          legendFormat = "{{job}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id         = 4
        title      = "Responses by status class"
        type       = "timeseries"
        gridPos    = { h = 8, w = 12, x = 12, y = 8 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [{
          expr         = "sum by (job, deployment_environment_name, status_class) (rate(http_server_duration_milliseconds_count{job=~\"$product\", deployment_environment_name=~\"$env\"}[5m]))"
          legendFormat = "{{job}} ({{deployment_environment_name}}) {{status_class}}"
          refId        = "A"
        }]
      },
    ]
  })
}

resource "grafana_dashboard" "platform_health" {
  folder    = grafana_folder.dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "Platform health"
    uid           = "platform-health"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-6h", to = "now" }
    refresh       = "1m"
    tags          = ["platform", "provisioned"]

    panels = [
      {
        id      = 1
        type    = "row"
        title   = "Nodes and filesystems"
        gridPos = { h = 1, w = 24, x = 0, y = 0 }
      },
      {
        id          = 2
        title       = "Nodes up"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 0, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none" } }
        targets     = [{ expr = "count(up{job=\"node\"} == 1)", refId = "A" }]
      },
      {
        id          = 3
        title       = "Worst filesystem used %"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 6, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percent", max = 100, thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "yellow", value = 80 }, { color = "red", value = 90 }] } } }
        targets = [{
          expr  = "max(100 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay|squashfs|devtmpfs|nsfs\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay|squashfs|devtmpfs|nsfs\"} * 100))"
          refId = "A"
        }]
      },
      {
        id      = 4
        type    = "row"
        title   = "PVE / PBS"
        gridPos = { h = 1, w = 24, x = 0, y = 5 }
      },
      {
        id          = 5
        title       = "Lowest zpool health"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 0, y = 6 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none" } }
        targets     = [{ expr = "min(pve_zpool_health{job=\"pve-host\"})", refId = "A" }]
      },
      {
        id          = 6
        title       = "PBS datastore used %"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 6, y = 6 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percent", max = 100, thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "yellow", value = 80 }] } } }
        targets = [{
          expr  = "max(pve_pbs_datastore_used_bytes{job=\"pve-host\"} / pve_pbs_datastore_size_bytes{job=\"pve-host\"} * 100)"
          refId = "A"
        }]
      },
      {
        id      = 7
        type    = "row"
        title   = "CNPG and backups"
        gridPos = { h = 1, w = 24, x = 0, y = 10 }
      },
      {
        id          = 8
        title       = "CNPG exporters up"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 0, y = 11 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none" } }
        targets     = [{ expr = "sum(cnpg_collector_up{namespace=\"data-prod\"})", refId = "A" }]
      },
      {
        id          = 9
        title       = "Oldest prod base backup (hours)"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 6, y = 11 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "h", thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "yellow", value = 12 }, { color = "red", value = 26 }] } } }
        targets = [{
          expr  = "max((time() - max by (cnpg_cluster) ({__name__=~\"cnpg_collector_last_available_backup_timestamp|barman_cloud_cloudnative_pg_io_last_available_backup_timestamp\", cnpg_cluster=~\"pg-.+\"} > 0)) / 3600)"
          refId = "A"
        }]
      },
      {
        id      = 10
        type    = "row"
        title   = "Valkey, ArgoCD, ESO, certificates"
        gridPos = { h = 1, w = 24, x = 0, y = 15 }
      },
      {
        id          = 11
        title       = "Valkey up (prod)"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 0, y = 16 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none" } }
        targets     = [{ expr = "min(redis_up{namespace=\"data-prod\"})", refId = "A" }]
      },
      {
        id          = 12
        title       = "ArgoCD apps OutOfSync"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 6, y = 16 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none" } }
        targets     = [{ expr = "count(argocd_app_info{sync_status=\"OutOfSync\"})", refId = "A" }]
      },
      {
        id          = 13
        title       = "ExternalSecrets failing"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 12, y = 16 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none" } }
        targets     = [{ expr = "count(externalsecret_status_condition{condition=\"Ready\", status=\"False\"})", refId = "A" }]
      },
      {
        id          = 14
        title       = "Certificates expiring < 14d"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 18, y = 16 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none" } }
        targets     = [{ expr = "count((certmanager_certificate_expiration_timestamp_seconds - time()) < 14 * 24 * 3600)", refId = "A" }]
      },
      {
        id      = 15
        type    = "row"
        title   = "Tunnel and synthetic uptime"
        gridPos = { h = 1, w = 24, x = 0, y = 20 }
      },
      {
        id          = 16
        title       = "Lowest cloudflared HA connections"
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 0, y = 21 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none" } }
        targets     = [{ expr = "min(cloudflared_tunnel_ha_connections)", refId = "A" }]
      },
      {
        id          = 17
        title       = "Prod readyz availability, 7d"
        type        = "stat"
        gridPos     = { h = 4, w = 18, x = 6, y = 21 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit", min = 0.9, max = 1, thresholds = { mode = "absolute", steps = [{ color = "red", value = null }, { color = "green", value = 0.995 }] } } }
        targets = [{
          expr         = "avg_over_time(probe_success{job=~\".+-prod-readyz\"}[7d])"
          legendFormat = "{{job}}"
          refId        = "A"
        }]
      },
    ]
  })
}
