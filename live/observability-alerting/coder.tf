# =============================================================================
# VLSI / Coder observability (2026-11-06): the two signals the new platform
# pieces need, in the same alerting stack as everything else.
#
# 1. vlsi-ws ResourceQuota near full. The quota already exists in the cluster
#    (10 pods, 14 GiB limits.memory) and KSM exports kube_resourcequota — the
#    Alloy allowlist keeps it (verified in the live ConfigMap). gitops#377's
#    PrometheusRule is INERT: there is no Prometheus Operator or ruler in the
#    cluster (metrics go to Grafana Cloud), so nothing evaluates that CR. This
#    file is the evaluating copy.
#
# 2. Coder down. coder.qnsc.vn is WARP-ONLY by design (no Cloudflare Access:
#    coder ssh and /api/v2 websockets do not follow an Access redirect), so a
#    public synthetic probe CANNOT reach it. The in-cluster scrape `up` series
#    (gitops platform/alloy, job="coder", port 2112) is the availability
#    signal; the alert is fatal at 5 minutes, prod critical with opt-in Teams.
#
# COST: two rule groups over series that already exist.
# =============================================================================

resource "grafana_rule_group" "vlsi_ws_quota" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (vlsi-ws quota)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-vlsi-ws-quota-near-full"
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
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        # Usage/hard ratio for the two ceilings that matter, kept as a raw
        # ratio so the 7-day data guard sees the healthy case. `and on
        # (resource)` restricts the vector to limits.memory and pods without
        # putting the 0.85 comparison into A.
        expr = join("\n", [
          "max by (resource) (",
          "  kube_resourcequota{namespace=\"vlsi-ws\", type=\"used\"}",
          "  / ignoring(type)",
          "  kube_resourcequota{namespace=\"vlsi-ws\", type=\"hard\"}",
          ")",
          "and on (resource)",
          "kube_resourcequota{namespace=\"vlsi-ws\", type=\"hard\", resource=~\"limits.memory|pods\"} > 0",
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
              params = [0.85]
            }
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    labels = {
      product  = "vlsi"
      env      = "prod"
      severity = "warning"
    }

    annotations = {
      summary = "vlsi-ws {{ $labels.resource }} is above 85% of its ResourceQuota for 15 minutes — new workspaces will fail to schedule."
    }
  }
}

resource "grafana_rule_group" "coder" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (coder)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name      = "k3s-coder-down"
    condition = "B"
    for       = "5m"
    # OK for the first deploy: the scrape job lands in a separate gitops PR, so
    # absence immediately after this applies is an ordering window, not an
    # outage. FLIP TO "Alerting" once `up{job="coder"}` has been seen (one
    # scrape); from then on absence means the scrape path is broken and must
    # page like a downed server.
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
        expr          = "up{job=\"coder\"}"
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
      product  = "vlsi"
      env      = "prod"
      severity = "critical"
      # Prod criticals already reach Teams after the severity split; explicit
      # opt-in keeps the page if the routing changes again.
      paging = "teams"
    }

    annotations = {
      summary = "Coder (coder.qnsc.vn) has not been scrapeable for 5 minutes — the VLSI workspace control plane is down. No public synthetic check exists: the host is WARP-only, so this in-cluster `up` is the availability signal."
    }
  }
}
