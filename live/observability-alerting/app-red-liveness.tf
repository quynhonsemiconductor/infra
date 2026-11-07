# =============================================================================
# App RED liveness — "the request-rate series stopped existing" (observability
# coverage audit 2026-11-07 §1; scope corrected in round 2, same day).
#
# THE GAP: `target_info` proves the OTLP metrics pipeline is alive, but it does
# NOT prove the product's RED family is arriving. The 11-07 audit first read
# `http_server_duration_milliseconds_*` as absent for every product — that was
# the Adaptive Metrics `__name__`-glob false negative (see below), and the SA
# then measured it live: 24 h `increase()` on the family was kb-api dev ~26k,
# kb-api prod ~26k, rova-api prod ~2.5k. The family is healthy today. The reason
# this rule still exists is that NOTHING would have noticed if it were not:
#
#   - k3s-<product>-telemetry-silent (telemetry-silent.tf) fires on
#     target_info absence only — the pipeline's front door;
#   - <product>-prod-http-5xx-rate needs traffic AND a 5xx share, so a product
#     whose RED family vanished is NoData/OK, i.e. "healthy";
#   - a dashboard cannot alert on its own blankness.
#
# So this file owns the ONE liveness probe for the RED family itself:
# `absent_over_time(http_server_duration_milliseconds_count{job, env}[<window>])`.
# That metric is the request counter: it is created by the first request and
# stays present for as long as traffic flows.
#
# ── WHY THE SELECTOR IS THE METRIC NAME, NOT `{__name__=~...}` ──────────────
# Adaptive Metrics aggregates this family. infra/live/adaptive-metrics/README.md
# documents that a bare `{__name__=~"http_server_.*"}` query returns nothing or
# a 422 under the rules, and that this has ALREADY produced two false "the
# metric does not exist" conclusions — the 11-07 coverage audit was the third.
# Query the family by name, with the kept labels (job,
# deployment_environment_name) — the same shape the dashboards and the 5xx
# rules use.
#
# ── SCOPE: ARMED ONLY WHERE TRAFFIC IS CONTINUOUS (round 3) ─────────────────
# `absent_over_time` fires on a product that has never served, so this map is an
# ALLOWLIST, not "every product". Measured live by the SA on 2026-11-07:
#
#   kb-api  dev   ~26,000 requests / 24 h, ~18/min, never a zero hour in 2 d
#   kb-api  prod  ~26,000 requests / 24 h, ~18/min, never a zero hour in 2 d
#   rova-api prod ~2,500 requests / 24 h, but ~112 of the last 168 HOURS had
#                 zero requests in the preceding 60 min (nights and weekends)
#
# rova prod is therefore NOT armed: an absent-rule above ~an hour fires through
# most nights and weekends, which is noise, not a signal. Its coverage stays
# where it belongs — the prod readyz probe (uptime-dev.tf / prod synthetics)
# and the Grafana SLO; a silent rova API is a user-visible outage those catch.
# rova dev, opshub dev and opshub prod are also excluded (zero traffic; opshub
# prod has had no request since its 2026-11-05 boot). Arm an environment in the
# change that first routes continuous traffic to it — the readiness probe is an
# ignored path and never creates this series.
#
# ── SEVERITY ───────────────────────────────────────────────────────────────
# kb prod is critical (Teams + devops@); kb dev is warning (email only). The
# notification policy routes on `env`, so the label must be the "prod"/"dev"
# spelling the policy matches (tests/static.sh enforces it).
# =============================================================================

locals {
  # job      — the OTLP-derived `job` label (`<service.namespace>/<service.name>`)
  # env      — deployment_environment_name, the AM-kept spelling
  # window   — how long the request counter may be absent before it counts
  # hold     — the rule's `for`
  # severity — critical pages; warning emails
  red_liveness = {
    kb_dev = {
      job      = "kb/kb-api"
      env      = "dev"
      product  = "kb"
      severity = "warning"
      window   = "30m"
      hold     = "5m"
    }
    kb_prod = {
      job      = "kb/kb-api"
      env      = "prod"
      product  = "kb"
      severity = "critical"
      window   = "30m"
      hold     = "5m"
    }
    # rova prod, rova dev, opshub dev, opshub prod: EXCLUDED — see the scope
    # block at the top. rova prod has ~112 zero-hours in 7 d (an hour-long
    # absent rule would fire most nights); it is covered by the readyz probe
    # and the SLO instead.
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
      for       = red.value.hold
      # The expression RETURNS 1 when the family is absent, so a real NoData
      # here means the rule itself failed to evaluate, not that RED is missing.
      no_data_state  = "OK"
      exec_err_state = "KeepLast"

      data {
        ref_id         = "A"
        query_type     = "instant"
        datasource_uid = data.grafana_data_source.prometheus.uid

        relative_time_range {
          # Duration in seconds + 60 s of evaluation slack.
          from = tonumber(trimsuffix(red.value.window, "m")) * 60 + 60
          to   = 0
        }

        model = jsonencode({
          refId         = "A"
          datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
          expr          = "absent_over_time(http_server_duration_milliseconds_count{job=\"${red.value.job}\", deployment_environment_name=\"${red.value.env}\"}[${red.value.window}])"
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
        summary = "${red.value.product} ${red.value.env}: no inbound-request metric (http_server_duration_milliseconds_count from ${red.value.job}) for ${red.value.window}. RED panels are blank and the 5xx rule is NoData — the request counter is not arriving, not merely idle."
        description = join("\n", [
          "Check, in this order:",
          "1. App serving? kubectl -n ${red.value.product}-${red.value.env} get pods; access logs.",
          "2. SDK still recording? An app change can drop HttpMetrics or its OTel views (job=~\"${red.value.job}\" on target_info alone shows whether OTLP is up).",
          "3. Collector converts it? Grafana Cloud Mimir: count by (job) (last_over_time(http_server_duration_milliseconds_count[1h])) — query the family BY NAME; a {__name__=~\"http_server_.*\"} glob returns nothing under Adaptive Metrics and is a known false negative.",
          "4. Adaptive Metrics rules unchanged? infra live/adaptive-metrics (http_server_ rule keeps job, service_*, deployment_environment_name, method, status_class, route, le).",
          "Armed only for continuous-traffic combinations (see the comment header for the measured 24 h counts).",
        ])
      }
    }
  }
}
