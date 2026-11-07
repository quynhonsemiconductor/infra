# =============================================================================
# App RED liveness — "the request-rate series stopped existing" (observability
# coverage audit 2026-11-07 §1).
#
# THE GAP: `target_info` proves the OTLP metrics pipeline is alive, but it does
# NOT prove the product's RED family is arriving. The 2026-11-07 audit measured
# `http_server_duration_milliseconds_*` as absent for every product over 24 h
# while target_info was present. The existing guards cannot see that:
#
#   - k3s-<product>-telemetry-silent (telemetry-silent.tf) fires on
#     target_info absence only — the pipeline's front door;
#   - <product>-prod-http-5xx-rate needs traffic AND a 5xx share, so a product
#     whose RED family vanished is NoData/OK, i.e. "healthy";
#   - a dashboard cannot alert on its own blankness.
#
# So this file owns the ONE liveness probe for the RED family itself:
# `absent_over_time(http_server_duration_milliseconds_count{job, env}[30m])`.
# That metric is the request counter: it is created by the first request and
# stays present for as long as traffic flows. Its absence for 30 minutes means
# one of: the SDK stopped recording (app change), the collector stopped
# converting (pipeline), Adaptive Metrics aggregated it away (rules), or the
# product stopped serving. All four are worth a page; the dashboard cannot
# distinguish them, but it does not have to.
#
# ── WHY THE SELECTOR IS THE METRIC NAME, NOT `{__name__=~...}` ──────────────
# Adaptive Metrics aggregates this family. infra/live/adaptive-metrics/README.md
# documents that a bare `{__name__=~"http_server_.*"}` query returns nothing or
# a 422 under the rules, and that this has ALREADY produced two false "the
# metric does not exist" conclusions. Query the family by name, with the kept
# labels (job, deployment_environment_name) — the same shape the dashboards and
# the 5xx rules use. If you are auditing coverage, use this expression, not a
# `__name__` glob.
#
# ── SCOPE: ARMED ONLY WHERE TRAFFIC IS PROVEN ───────────────────────────────
# `absent_over_time` fires on a product that has never served, so the map below
# is an ALLOWLIST, not "every product". rova prod/dev, opshub dev and kb dev
# serve requests today (rova prod: GitHub webhooks; kb dev: the browser app).
# opshub prod and kb prod have no API traffic yet — their 5xx rules are
# correctly NoData/OK — so they are EXCLUDED. Arm one when traffic starts; the
# exact check is in its comment.
#
# The 2026-11-05 series proof (kb-prod.tf: "SERIES PROVEN IN MIMIR") shows
# `job="kb/kb-api"` and `deployment_environment_name="dev"` on this family, so
# the selector below matches the live shape, not an assumed one.
#
# ── SEVERITY ───────────────────────────────────────────────────────────────
# prod critical (Teams + devops@), dev warning (email only) — the notification
# policy routes on `env`, so the label must be the "prod"/"dev" spelling the
# policy matches (tests/static.sh enforces it).
# =============================================================================

locals {
  # job        — the OTLP-derived `job` label (`<service.namespace>/<service.name>`)
  # env        — deployment_environment_name, the AM-kept spelling
  # severity   — prod pages; dev warns
  red_liveness = {
    rova_prod = {
      job      = "rova/rova-api"
      env      = "prod"
      product  = "rova"
      severity = "critical"
    }
    rova_dev = {
      job      = "rova/rova-api"
      env      = "dev"
      product  = "rova"
      severity = "warning"
    }
    opshub_dev = {
      job      = "opshub/opshub-api"
      env      = "dev"
      product  = "opshub"
      severity = "warning"
    }
    # opshub prod: EXCLUDED — the API has served no request since it was
    # deployed (2026-11-07: zero access-log lines, zero spans). Arm it in the
    # same change that first routes user traffic to it; the readiness probe is
    # an ignored path and never creates this series.
    kb_dev = {
      job      = "kb/kb-api"
      env      = "dev"
      product  = "kb"
      severity = "warning"
    }
    # kb prod: EXCLUDED — kb.qnsc.vn serves, but the API has stayed under the
    # 50-requests/10m floor since launch (the 5xx rule is NoData/OK). Arm it
    # with the first real prod traffic.
  }
}

resource "grafana_rule_group" "app_red_liveness" {
  count            = local.onprem_live ? 1 : 0
  name             = "onprem (app RED)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.red_liveness
    iterator = red

    content {
      name      = "k3s-${red.key}-red-missing"
      condition = "B"
      for       = "5m"
      # The expression RETURNS 1 when the family is absent, so a real NoData
      # here means the rule itself failed to evaluate, not that RED is missing.
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
          expr          = "absent_over_time(http_server_duration_milliseconds_count{job=\"${red.value.job}\", deployment_environment_name=\"${red.value.env}\"}[30m])"
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
        product  = red.value.product
        env      = red.value.env
        severity = red.value.severity
      }

      annotations = {
        summary = "${red.value.product} ${red.value.env}: no inbound-request metric (http_server_duration_milliseconds_count from ${red.value.job}) for 30 minutes. RED panels are blank and the 5xx rule is NoData — the request counter is not arriving, not merely idle."
        description = join("\n", [
          "Check, in this order:",
          "1. App serving? kubectl -n ${red.value.product}-${red.value.env} get pods; access logs.",
          "2. SDK still recording? An app change can drop HttpMetrics or its OTel views (job=~\"${red.value.job}\" on target_info alone shows whether OTLP is up).",
          "3. Collector converts it? Grafana Cloud Mimir: count by (job) (last_over_time(http_server_duration_milliseconds_count[1h])) — query the family BY NAME; a {__name__=~\"http_server_.*\"} glob returns nothing under Adaptive Metrics and is a known false negative.",
          "4. Adaptive Metrics rules unchanged? infra live/adaptive-metrics (http_server_ rule keeps job, service_*, deployment_environment_name, method, status_class, route, le).",
        ])
      }
    }
  }
}
