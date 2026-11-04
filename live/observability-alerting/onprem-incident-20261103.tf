# =============================================================================
# Alerts added after the 2026-11-03 rova prod outage (~1h40). Same shape as
# onprem-data-p0.tf (one map, one Prometheus rule group) plus one Loki group.
# Gated like the rest of the on-prem set by `onprem_alerts_enabled`.
#
# METRICS (each checked live on 2026-11-03 unless noted):
#   kube_deployment_spec_replicas / _status_replicas_available  kube-state-metrics
#   cnpg_backends_total, cnpg_pg_settings_setting{name="max_connections"}
#       CNPG 1.30 default monitoring queries (`backends`, `pg_settings`). NOT
#       scraped before gitops#141 (the collector allowlist dropped them); until
#       that syncs the rules see no data and stay OK.
#   {job="integrations/kubernetes/journal"}  Loki, kernel AppArmor denials only
#       (gitops#141 ships them; the stream is empty until then).
#
# The Postgres readiness rules (onprem-workloads.tf) were tightened to 2m in
# the same change, and the rova prod readyz check (rova-prod.tf) moved to 60s
# from two probes.
#
# Labels route through the notification policy: env=production pages Teams +
# email; env=development is email (plus Teams only with paging=teams).
# =============================================================================
locals {
  onprem_incident_rules = {
    pg_connections_prod = {
      name = "k3s-pg-connections-over-80-percent-prod"
      # Client backends (every state, idle included: an idle session still holds
      # a slot) over max_connections, per instance pod.
      expr      = "sum by (namespace, cnpg_cluster, pod) (cnpg_backends_total{cluster=\"qnsc-onprem\", namespace=\"data-prod\"}) / on (namespace, cnpg_cluster, pod) max by (namespace, cnpg_cluster, pod) (cnpg_pg_settings_setting{cluster=\"qnsc-onprem\", namespace=\"data-prod\", name=\"max_connections\"})"
      op        = "gt"
      threshold = 0.8
      for       = "5m"
      no_data   = "OK"
      product   = "rova"
      env       = "production"
      severity  = "critical"
      summary   = "Postgres {{ $labels.cnpg_cluster }} ({{ $labels.pod }}) is using over 80% of max_connections for 5 minutes. New connections will soon be refused; check pool sizes and long-held sessions."
    }
    pg_connections_dev = {
      name      = "k3s-pg-connections-over-80-percent-dev"
      expr      = "sum by (namespace, cnpg_cluster, pod) (cnpg_backends_total{cluster=\"qnsc-onprem\", namespace=\"data-dev\"}) / on (namespace, cnpg_cluster, pod) max by (namespace, cnpg_cluster, pod) (cnpg_pg_settings_setting{cluster=\"qnsc-onprem\", namespace=\"data-dev\", name=\"max_connections\"})"
      op        = "gt"
      threshold = 0.8
      for       = "5m"
      no_data   = "OK"
      product   = "platform"
      env       = "development"
      severity  = "warning"
      summary   = "Dev Postgres {{ $labels.cnpg_cluster }} ({{ $labels.pod }}) is using over 80% of max_connections for 5 minutes."
    }
    deployment_unavailable_prod = {
      name = "k3s-deployment-unavailable-prod"
      # Missing replicas per Deployment. A normal rolling update closes the gap
      # well inside 5 minutes; a stuck rollout or a crash loop does not.
      expr      = "max by (namespace, deployment) (kube_deployment_spec_replicas{cluster=\"qnsc-onprem\", namespace=~\"rova-prod|opshub-prod|kb-prod|data-prod\"} - kube_deployment_status_replicas_available{cluster=\"qnsc-onprem\", namespace=~\"rova-prod|opshub-prod|kb-prod|data-prod\"})"
      op        = "gt"
      threshold = 0
      for       = "5m"
      no_data   = "OK"
      product   = "platform"
      env       = "production"
      severity  = "critical"
      summary   = "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} has had fewer available replicas than desired for 5 minutes."
    }
  }
}

resource "grafana_rule_group" "onprem_incident_20261103" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (availability)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.onprem_incident_rules
    iterator = r
    content {
      name           = r.value.name
      condition      = "B"
      for            = r.value.for
      no_data_state  = r.value.no_data
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
          expr          = r.value.expr
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
                type   = r.value.op
                params = [r.value.threshold]
              }
            }
          ]
          intervalMs    = 1000
          maxDataPoints = 43200
        })
      }

      labels = {
        product  = r.value.product
        env      = r.value.env
        severity = r.value.severity
      }

      annotations = {
        summary = r.value.summary
      }
    }
  }
}

# ── AppArmor denials on the nodes (Loki) ────────────────────────────────────
# The collector ships ONLY kernel/audit journal lines matching
# apparmor="DENIED" (gitops#141), so any line here is a denial. Beyla
# (comm="beyla") is excluded: its denials are known and get their own fix.
# for = 0m: count_over_time over 10m already is the window; one denial is the
# signal. Absence is normal (no_data OK).
resource "grafana_rule_group" "onprem_apparmor" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (apparmor)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "k3s-apparmor-denied"
    condition      = "C"
    for            = "0m"
    no_data_state  = "OK"
    exec_err_state = "KeepLast"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.logs.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId      = "A"
        datasource = { type = "loki", uid = data.grafana_data_source.logs.uid }
        expr       = "sum by (instance) (count_over_time({cluster=\"qnsc-onprem\", job=\"integrations/kubernetes/journal\"} |= `apparmor=\"DENIED\"` != `comm=\"beyla\"` [10m]))"
        queryType  = "instant"
        instant    = true
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
        type       = "reduce"
        datasource = { type = "__expr__", uid = "__expr__" }
        expression = "A"
        reducer    = "last"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        datasource = { type = "__expr__", uid = "__expr__" }
        expression = "B"
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
      summary = "AppArmor denied {{ $values.B }} operation(s) on node {{ $labels.instance }} in the last 10 minutes (Beyla excluded). Explore: {cluster=\"qnsc-onprem\", job=\"integrations/kubernetes/journal\"}."
    }
  }
}
