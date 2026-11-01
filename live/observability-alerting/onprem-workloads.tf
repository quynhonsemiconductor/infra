# =============================================================================
# On-prem WORKLOAD alerts — CrashLoop and Postgres readiness (ONPREM-PLAN §12).
#
# Part of the 2026-11-01 fast-track alert set. These need Kubernetes metrics
# (kube-state-metrics), so they are gated by the SAME flag as the existing
# on-prem rules (`onprem_alerts_enabled`, onprem-k3s.tf, default false) and arm
# in the PR that lands the k8s-monitoring collector. Uptime does NOT wait for
# that flag — it is Synthetic Monitoring and lives in uptime-dev.tf.
#
# ── METRICS ────────────────────────────────────────────────────────────────
# kube-state-metrics (deployed by k8s-monitoring):
#   kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} 0/1
#   kube_pod_status_ready{condition="true"}                             0/1
# Pod names for CNPG clusters are `<cluster>-<ordinal>` (§6.3: pg-rova,
# pg-dev); the regex keeps CNPG's own jobs out.
#
# ── ROUTING ────────────────────────────────────────────────────────────────
# prod rules carry env=production (Teams + devops@ via the root policy). dev
# rules carry env=development + paging=teams (uptime-dev.tf's policy child) —
# today a dev crash loop would otherwise only reach email, and the owner asked
# for Teams on the fast track.
#
# ── NOISE CONTROL ──────────────────────────────────────────────────────────
# `for: 10m` for CrashLoop (a single restart is not an alert; ten minutes of
# CrashLoopBackOff is). Postgres readiness uses `for: 5m` — a pod that is not
# ready for five minutes on a single-instance cluster is an outage, and one
# instance in dev has no failover to wait out.
# =============================================================================

# ── CrashLoop, prod + platform namespaces ─────────────────────────────────
resource "grafana_rule_group" "onprem_crashloop_prod" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (crashloop — prod)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-pod-crashloop-prod"
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
        expr = join("\n", [
          "max by (namespace, pod, container) (",
          "  kube_pod_container_status_waiting_reason{",
          "    reason=\"CrashLoopBackOff\",",
          "    namespace=~\"rova-prod|opshub-prod|platform|argocd|data-prod|restore-test\"",
          "  }",
          ") > 0",
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
      severity = "warning"
    }

    annotations = {
      summary     = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) has been in CrashLoopBackOff for 10 minutes (§12)."
      description = "kubectl -n {{ $labels.namespace }} logs {{ $labels.pod }} -c {{ $labels.container }} --previous"
    }
  }
}

# ── CrashLoop, dev namespaces ──────────────────────────────────────────────
resource "grafana_rule_group" "onprem_crashloop_dev" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (crashloop — dev)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-pod-crashloop-dev"
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
        expr = join("\n", [
          "max by (namespace, pod, container) (",
          "  kube_pod_container_status_waiting_reason{",
          "    reason=\"CrashLoopBackOff\",",
          "    namespace=~\"rova-dev|opshub-dev|kb-dev|data-dev|ai|ai-lab\"",
          "  }",
          ") > 0",
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
      env      = "development"
      paging   = "teams"
      severity = "warning"
    }

    annotations = {
      summary     = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) has been in CrashLoopBackOff for 10 minutes (§12)."
      description = "kubectl -n {{ $labels.namespace }} logs {{ $labels.pod }} -c {{ $labels.container }} --previous"
    }
  }
}

# ── Postgres readiness: pg-rova (prod) ────────────────────────────────────
# The cluster is not up yet (PLT-B7). Until it exists the series is absent and
# `no_data_state = OK` keeps the rule silent; the rule is written for the move,
# not for today's absence.
resource "grafana_rule_group" "onprem_pg_rova_ready" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (postgres — pg-rova)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-pg-rova-not-ready"
    condition      = "B"
    for            = "5m"
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
        expr          = "min by (namespace, pod) (kube_pod_status_ready{condition=\"true\", namespace=\"data-prod\", pod=~\"pg-rova-[0-9].*\"}) < 1"
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
      product  = "rova"
      env      = "production"
      severity = "critical"
    }

    annotations = {
      summary = "pg-rova pod {{ $labels.pod }} has not been Ready for 5 minutes — the prod database is down or starting (ONPREM-PLAN §12)."
    }
  }
}

# ── Postgres readiness: pg-dev ────────────────────────────────────────────
resource "grafana_rule_group" "onprem_pg_dev_ready" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (postgres — pg-dev)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-pg-dev-not-ready"
    condition      = "B"
    for            = "5m"
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
        expr          = "min by (namespace, pod) (kube_pod_status_ready{condition=\"true\", namespace=\"data-dev\", pod=~\"pg-dev-[0-9].*\"}) < 1"
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
      env      = "development"
      paging   = "teams"
      severity = "critical"
    }

    annotations = {
      summary = "pg-dev pod {{ $labels.pod }} has not been Ready for 5 minutes — the shared dev database is down or starting."
    }
  }
}
