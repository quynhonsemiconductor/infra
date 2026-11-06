# =============================================================================
# "A signed-in person was rate-limited" — rova and opshub prod (2026-11-05).
#
# WHY THIS EXISTS (owner requirement, 2026-11-05): both products size their
# per-user tiers so that normal work never reaches them. A 429 to a signed-in
# user in production is therefore never routine back-pressure — it is a client
# looping or a tier in the wrong shape. Both guards already LOG the refusal;
# these rules turn the first one in a 15-minute window into a Teams warning so
# it is seen the same day, not when somebody complains.
#
# ── THE COUNTERS (the two PRs that added them) ──────────────────────────────
# rova#905 — libs/platform/src/rate-limit/rate-limit.metrics.ts
#   createCounter('rate.limit.rejected')  ->  rate_limit_rejected_total
#   labels: tier, route, keyed_by ("user" | "address").
#   ONLY keyed_by="user" is a signed-in caller. "address" is the pre-auth
#   per-IP floor refusing an UNVERIFIED request — that bucket is doing its job
#   and must never warn.
# opshub#555 — libs/platform/src/rate-limit/rate-limit.guard.ts
#   createCounter('rate_limit.authenticated_429')
#                                        ->  rate_limit_authenticated_429_total
#   labels: tier, route. Emitted only after identity verified the caller, so
#   every increment is attributable to a real person — no filter needed.
#
# OPEN (audit 2026-11-06): neither counter has ANY series in a 7-day window.
# A lazy counter that has never incremented is indistinguishable from a
# counter that was never wired, so the rule is kept (a signed-in 429 must
# page) and the wiring is verified the first time a counter appears:
#   count by (__name__) ({__name__=~"rate_limit_.*"})
# If that stays empty after a known refusal, the product side is broken — drop
# the rule then, not now.
#
# Both guards keep the USER ID out of the labels on purpose (an id would mint a
# series per person); it is in the guard's warning log, which is where the
# "who" is found:
#   opshub  event=rate_limit.authenticated_429, userId, tier, route, limit
#   rova    "Rate limit exceeded", key, tier, ip, userId, route
#
# NAME MAPPING: OTel counter -> Prometheus `_total` is the pipeline's existing
# behaviour, visible in Mimir today on these same jobs
# (`identity_security_events_total`, `queue_processed_total`). Nothing renames
# these counters: no Adaptive Metrics rule matches the `rate_limit_` prefix
# (live/adaptive-metrics keeps `http_server_`, `http_client_`, `db_client_`,
# `node_cpu`), so the full bounded label set survives to Mimir.
#
# ── 15 MINUTES, WARNING ─────────────────────────────────────────────────────
# The ask is "any 429 to a signed-in user in 15 minutes -> warn". A 15m
# increase keeps the alert raised while the same loop keeps being refused (a
# 1m window would drop it between two refusals of one incident) and clears
# 15 minutes after the client is fixed.
#
# `severity = "warning"`, not critical: nothing is down, but a person is being
# blocked from work. `env = "prod"` is enough to reach Teams —
# grafana_notification_policy.root's prod child (main.tf) sends every
# production alert to Teams AND devops@ email, so no per-rule contact point.
#
# NO `for:` ON PURPOSE. The 15m range IS the debounce; `for = "5m"` would only
# delay a signal whose window already spans 15 minutes.
#
# ── NO_DATA = OK ────────────────────────────────────────────────────────────
# No series means nobody was refused, and until the next dev/prod image bump
# the counters do not exist at all: the images running on 2026-11-05 (rova
# v0.8.8, opshub v0.4.8) predate #905 / #555 — verified against Mimir, which
# holds `http_server_*` for both products but zero `rate_limit_*` series.
# A counter that has never appeared, or vanished, must not page; the
# deployment-missing rules already cover "the pod is not there".
# =============================================================================

locals {
  prod_rate_limit_429 = {
    rova = {
      name    = "rova-prod-authenticated-429"
      product = "rova"
      metric  = "rate_limit_rejected_total"
      # rova counts the per-user and the per-address refusal in ONE counter;
      # only `keyed_by="user"` is a signed-in caller.
      selector = "job=~\"rova/.+\", deployment_environment_name=\"prod\", keyed_by=\"user\""
      summary  = "rova prod: a signed-in user was answered 429 by a rate-limit tier in the last 15 minutes (tier {{ $labels.tier }}, route {{ $labels.route }})."
      checks = join("\n", [
        "FIRST CHECKS",
        "1. Which tier/route? They are the alert's own labels: tier {{ $labels.tier }} on route {{ $labels.route }}.",
        "2. Who? The guard logs `Rate limit exceeded` with userId, tier, route and keyed_by. Loki: `{namespace=\"rova-prod\"} |= \"Rate limit exceeded\"` over the same window.",
        "3. Did a deploy start it? Check the Deploys annotation — a client polling in a loop shows up here first.",
        "4. Is the tier supposed to be tight? DEFAULT is 1200/min per user (sized so a page-refresh burst never touches it) — a DEFAULT refusal is the defect. STRICT is 20/min and guards uploads and invitation email; a refusal there can be the control working on a genuine loop, so confirm before changing it.",
        "5. Genuine abuse from one compromised account: the logged userId answers that directly.",
        "DO NOT raise STRICT to clear the alert before step 4 says the client is looping.",
        "Runbook: https://github.com/quynhonsemiconductor/rova/blob/main/docs/runbooks/alerts/rova-prod-authenticated-429.md",
      ])
    }
    opshub = {
      name    = "opshub-prod-authenticated-429"
      product = "opshub"
      metric  = "rate_limit_authenticated_429_total"
      # opshub's counter is emitted only after identity verified the caller, so
      # it needs no keyed_by filter.
      selector = "job=~\"opshub/.+\", deployment_environment_name=\"prod\""
      summary  = "opshub prod: a signed-in user was answered 429 by a rate-limit tier in the last 15 minutes (tier {{ $labels.tier }}, route {{ $labels.route }})."
      checks   = "Runbook: https://github.com/quynhonsemiconductor/opshub/blob/main/docs/runbooks/alerts/authenticated-rate-limited.md"
    }
  }
}

resource "grafana_rule_group" "prod_rate_limit_429" {
  for_each = local.prod_rate_limit_429

  name             = "${each.key} (prod rate limit)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = each.value.name
    condition      = "B"
    no_data_state  = "OK"
    exec_err_state = "KeepLast"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 960 # the 15m window plus a minute of slack on each read
        to   = 0
      }

      model = jsonencode({
        refId      = "A"
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        # `sum by (job, tier, route)` keeps ONE series per refused tier+route —
        # so the notification names where — and drops every other label, so the
        # instance set stays bounded by the tier union times the route table.
        # `> 0`, not `>= 1`: a single refusal is 1, but Prometheus extrapolates
        # an increase and may return 0.9, which must still fire.
        expr = join("\n", [
          "sum by (job, tier, route) (",
          "  increase(${each.value.metric}{",
          "    ${each.value.selector}",
          "  }[15m])",
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
      product  = each.value.product
      env      = "prod"
      severity = "warning"
    }

    annotations = {
      summary = each.value.summary
      description = join("\n", [
        "PromQL: sum by (job, tier, route) (increase(${each.value.metric}{${each.value.selector}}[15m])) > 0",
        "Any value in production is a defect: the per-user tiers are sized so that normal work never reaches them.",
        "",
        each.value.checks,
      ])
    }
  }
}
