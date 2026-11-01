# =============================================================================
# The remaining on-prem signals from ONPREM-PLAN §12: node memory pressure,
# ESO sync health, ArgoCD application health, certificate expiry, and the
# Cloudflare tunnel connector.
#
# GATED like the rest of the on-prem set (`onprem_alerts_enabled`, default
# false): every series here comes from the k8s-monitoring collector
# (gitops platform/alloy) and cert-manager/cloudflared scrapes, so the groups
# arm together with the collector, not before it. The fast-track uptime and
# CrashLoop/Postgres set is separate (uptime-dev.tf, onprem-workloads.tf).
#
# METRIC SOURCE (each verified against the collector's allowlists, not from
# memory): node_memory_* (node-exporter, job="node"); externalsecret_status_*
# (ESO operator, annotation autodiscovery); argocd_app_info (ArgoCD metrics
# Services, scraped as job=<service name>); certmanager_certificate_* (the
# cert-manager controller on 9402); cloudflared_tunnel_ha_connections (the
# connector's own metrics on 2000).
#
# NOISE CONTROL: every rule has a `for:` of 10–15 minutes and no_data_state
# OK (absence is covered by the node-down rule, not by five independent
# "series vanished" pages). exec_err_state is KeepLast — a Prometheus/Loki
# fault must not page as a product outage.
# =============================================================================

# ── Node memory pressure ───────────────────────────────────────────────────
resource "grafana_rule_group" "onprem_memory" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (k3s — memory)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-node-memory-available-under-10-percent"
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
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "min by (instance) (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"
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
              params = [0.1]
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
      summary = "Node {{ $labels.instance }} has had under 10% memory available for 10 minutes — the estate is one container restart from an OOM kill (§12)."
    }
  }
}

# ── ESO: an ExternalSecret that stops syncing is the 2026-09-06 shape ──────
resource "grafana_rule_group" "onprem_eso_sync" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (external-secrets)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-externalsecret-not-ready"
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
        expr          = "max by (namespace, name) (externalsecret_status_condition{condition=\"Ready\", status=\"False\"}) > 0"
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
      summary = "ExternalSecret {{ $labels.namespace }}/{{ $labels.name }} has not been Ready for 15 minutes — a secret is stale or missing (§12). This is the 2026-09-06 failure shape."
    }
  }
}

# ── ArgoCD: an Application stuck Degraded ──────────────────────────────────
resource "grafana_rule_group" "onprem_argocd_apps" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (argocd)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-argocd-app-degraded"
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
        expr          = "max by (name, namespace) (argocd_app_info{health_status=\"Degraded\"}) > 0"
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
      summary = "ArgoCD Application {{ $labels.name }} in namespace {{ $labels.namespace }} has been Degraded for 15 minutes (§12)."
    }
  }
}

# ── Certificates expiring within 14 days ───────────────────────────────────
# cert-manager renews ~30 d before expiry, so 14 d left means renewal has been
# failing for two weeks — not "a cert is about to expire", but "renewal is
# broken".
resource "grafana_rule_group" "onprem_cert_expiry" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (cert-manager)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  rule {
    name           = "k3s-certificate-expires-within-14-days"
    condition      = "B"
    for            = "1h"
    no_data_state  = "OK"
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
        expr          = "(certmanager_certificate_expiration_timestamp_seconds - time()) < 14 * 24 * 3600"
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
      summary = "Certificate {{ $labels.name }} ({{ $labels.namespace }}) expires in under 14 days — cert-manager renewal has been failing (§12)."
    }
  }
}

# ── Cloudflare tunnel connectors ───────────────────────────────────────────
# `cloudflared_tunnel_ha_connections` is the number of HA connections a
# connector currently holds. Zero on a RUNNING connector means the tunnel is
# down and every route 502s. Two replicas exist (§5.3); the rule fires on the
# MINIMUM, i.e. when at least one connector has zero for 10 minutes.
resource "grafana_rule_group" "onprem_tunnel" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (cloudflared)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-cloudflared-tunnel-down"
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
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "min by (pod) (cloudflared_tunnel_ha_connections)"
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
      summary = "cloudflared connector {{ $labels.pod }} has held zero HA connections for 10 minutes — the tunnel is down and every route is 502 (§12)."
    }
  }
}
