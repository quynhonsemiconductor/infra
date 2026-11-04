# =============================================================================
# PROD app 5xx-rate alerts — rova, opshub and kb (P3 launch, 2026-11-04).
#
# These were written once, in opshub-prod-app.tf, then removed in the same day
# because `http_server_*` came back empty from Mimir — the collector was not
# putting an environment on the app series, so every per-env query returned
# nothing (gitops#242 added `env`; the Adaptive Metrics rules keep
# `deployment_environment_name`, not `env`, which is why `env` vanished for
# every `http_*` family). The collector now emits
# `deployment_environment_name="dev"|"prod"` on the datapoints (gitops: the
# `env-label` data processor), which is exactly the label the
# `http_server_` keep-list preserves — so these rules are re-armed here.
#
# ── THE SERIES ─────────────────────────────────────────────────────────────
# `HttpMetrics` (app-platform, `packages/observability/src/metrics.ts`) records
# `http.server.duration` (ms) with `route`, `method` and `status_class` on every
# inbound request. OTLP -> Prometheus renders it
# `http_server_duration_milliseconds_{bucket,sum,count}`; the `_count` series is
# the per-request count carrying `status_class`, which is what makes a TRUE 5xx
# share computable. It is NOT `http_server_errors_total`: that counter increments
# for every status >= 400 (4xx included), so it answers a different question.
#
# Adaptive Metrics keeps `job, service_namespace, service_name,
# deployment_environment_name, method, status_class, route, le` for this family;
# `job` is `<product>/<service>` (`rova/rova-api`), so `job=~"<product>/.+"` is
# the product split, and `deployment_environment_name="prod"` is the
# environment split.
#
# ── THE 50-REQUESTS/10m FLOOR ──────────────────────────────────────────────
# A ratio over a handful of requests is not a rate: 1 failure out of 3 is 33%
# and pages at 03:00 for nothing. The numerator/denominator pair is evaluated
# only when the denominator (all requests in the same 10m window) is at least
# 50 — the floor the owner set for this alert. The ratio and the floor are
# separate expressions joined with `and`, so both must hold:
#
#   (5xx count / all count) > 0.05   AND   all count >= 50
#
# ── NO_DATA ────────────────────────────────────────────────────────────────
# `no_data_state = "OK"`: opshub prod has no API workload yet, and a brand-new
# deployment has no series until its first minute of traffic. Absence is "not
# serving", not "broken"; the deployment-missing rules already page on that.
#
# ── ROUTING ────────────────────────────────────────────────────────────────
# `env = "production"` matches grafana_notification_policy.root's prod children
# (Teams + devops@ email). `product` and `env` are also the notification
# group_by keys, so rova and opshub cannot group into one notification.
# =============================================================================

locals {
  prod_http_5xx = {
    rova = {
      name    = "rova-prod-http-5xx-rate"
      job     = "rova/.+"
      product = "rova"
      summary = "rova prod: more than 5% of API requests returned 5xx for 10 minutes (at least 50 requests in the window). Check the API logs, pg-rova and the upstream identity/SCM calls; compare with rova-dev for the same route."
    }
    opshub = {
      name    = "opshub-prod-http-5xx-rate"
      job     = "opshub/.+"
      product = "opshub"
      summary = "opshub prod: more than 5% of API requests returned 5xx for 10 minutes (at least 50 requests in the window). Check the API logs and the pg-opshub dependency first."
    }
    kb = {
      name    = "kb-prod-http-5xx-rate"
      job     = "kb/.+"
      product = "kb"
      # kb's series come from the Python exporter added in qnsc-kb-backend#369,
      # which records the SAME `http.server.duration` family with route/method/
      # status_class, so this rule needs no shape change: the Adaptive Metrics
      # keep-list keeps the same labels and the histogram `_count` carries 5xx.
      # Silent until a kb prod API serves traffic (no_data_state = OK).
      summary = "kb prod: more than 5% of API requests returned 5xx for 10 minutes (at least 50 requests in the window). Check the API logs, the TEI embedding service and pg-kb first."
    }
  }
}

resource "grafana_rule_group" "prod_http_5xx" {
  for_each = local.prod_http_5xx

  name             = "${each.key} (prod http 5xx)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = each.value.name
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "KeepLast"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        # 10m window + 1m of evaluation slack on each read of the range vector.
        from = 660
        to   = 0
      }

      model = jsonencode({
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        # `sum by (job)` on both sides keeps each side an instant vector (the
        # set operator `and` is vector-only) and drops every other label, so the
        # ratio is ONE series for the product+env (per-route noise belongs in the
        # dashboard, not a page). The floor is a second, independent expression
        # joined with `on(job)`; `and` keeps the ratio only while the floor holds.
        expr = join("\n", [
          "(",
          "  sum by (job) (increase(http_server_duration_milliseconds_count{",
          "    status_class=\"5xx\",",
          "    job=~\"${each.value.job}\",",
          "    deployment_environment_name=\"prod\"",
          "  }[10m]))",
          "  /",
          "  sum by (job) (increase(http_server_duration_milliseconds_count{",
          "    job=~\"${each.value.job}\",",
          "    deployment_environment_name=\"prod\"",
          "  }[10m]))",
          ") > 0.05",
          "and on(job)",
          "sum by (job) (increase(http_server_duration_milliseconds_count{",
          "  job=~\"${each.value.job}\",",
          "  deployment_environment_name=\"prod\"",
          "}[10m])) >= 50",
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
      product  = each.value.product
      env      = "production"
      severity = "critical"
    }

    annotations = {
      summary = each.value.summary
      description = join("\n", [
        "PromQL: sum by (job) (increase(http_server_duration_milliseconds_count{status_class=\"5xx\", job=~\"${each.value.job}\", deployment_environment_name=\"prod\"}[10m])) / sum by (job) (increase(http_server_duration_milliseconds_count{job=~\"${each.value.job}\", deployment_environment_name=\"prod\"}[10m])) > 0.05",
        "Floor: at least 50 requests in the same 10m window (sum by (job) (increase(...)) >= 50).",
      ])
    }
  }
}
