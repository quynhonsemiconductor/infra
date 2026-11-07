# =============================================================================
# Product overview — ONE dashboard, variables (product, env), every product
# (coverage audit 2026-11-07 §4).
#
# Today each product would need its own copy of the same six questions, and
# rova still has the AWS-era pair the pruner is about to delete. This is the
# replacement: one templated surface, no per-product fork.
#
# ── SERIES IT READS (all already in Mimir) ─────────────────────────────────
#   http_server_duration_milliseconds_*   RED, per job/env (app-red-liveness.tf
#                                         proves liveness; this renders it)
#   job_runs_total / job_failures_total   scheduled work (app-platform
#                                         JobMetrics, job_name label)
#   job_duration_milliseconds_*           the same jobs' durations (histogram;
#                                         p95 by job_name)
#   celery_task_runs_total / celery_task_failures_total /
#   celery_task_duration_milliseconds_*
#                                         kb's Celery worker (same questions,
#                                         different names; the `or` in each
#                                         panel makes one panel answer both).
#                                         kb's Celery beat now runs (SA note
#                                         2026-11-07 — the earlier "no beat"
#                                         caveat is history)
#   queue_processed_total / queue_failures_total / queue_lag_seconds_* /
#   outbox_relay_pass_failed_total{relay} outbox/relay throughput, backlog age
#                                         (histogram) and pass failures
#   auth_login_total{method, outcome}     logins (rova today, opshub shares the
#                                         lib; kb: none by design — team note)
#   identity_security_events_total{event} auth security events (same coverage;
#                                         label is `event`, NOT `type` —
#                                         source-verified 2026-11-07)
#   db_pool_in_use / db_pool_waiting      connection-pool saturation
#   v8js_memory_heap_used_bytes / nodejs_eventloop_utilization
#                                         Node runtime; the Python products
#                                         have no equivalent yet (noValue says so)
#   Loki {namespace="<product>-<env>"}    error lines, and the trace link
#   Tempo (dashboard link)                trace search filtered by service.name
#
# ── WHY CUSTOM VARIABLES, NOT label_values(...) ────────────────────────────
# A query variable over the RED family goes EMPTY when that family is not
# arriving, and Grafana then renders every panel blank with no explanation —
# the exact shape of the 2026-11-07 audit's "RED = 0 for every product". The
# product list is a small closed set and the namespace is `<product>-<env>`,
# so the variables are static and the dashboard always renders; a "RED series
# present" panel states whether the data is there.
#
# ── FAMILIES VERIFIED TO EXIST (round 2, at least one product; the item-5
#    names re-verified in source 2026-11-07: packages/observability
#    metrics.ts, identity nest/observability.ts, AbstractOutboxRelay,
#    qnsc-kb-backend otel_metrics.py) ────────────────────────────────────────
#   job_runs_total{job_name=...}      rova + opshub workers (SA, 2026-11-07)
#   queue_processed_total             rova/opshub AbstractOutboxRelay
#                                     (`QueueMetrics.recordProcessed`)
#   db_pool_in_use / db_pool_waiting  rova/opshub DrizzleProvider (DbPoolMetrics)
#   v8js_memory_heap_* / nodejs_eventloop_utilization
#                                     @opentelemetry/instrumentation-runtime-node
#                                     is in both products' lockfiles
#   celery_task_*                     kb only; kb's Celery beat NOW runs
#                                     (SA, 2026-11-07), so the panels carry
#                                     data for kb today
#   auth_login_total / identity_security_events_total
#                                     rova today; opshub shares the lib; empty
#                                     for kb (team note) — panels say so
#
# ── TRACE SEARCH ───────────────────────────────────────────────────────────
# The dashboard link opens Explore on the Tempo data source with a TraceQL
# query for `service.name =~ "<product>.*"`. The data source uid is looked up
# by name (`grafanacloud-<slug>-traces`, the same suffix convention as the
# `-logs` lookup in main.tf); if Grafana Cloud ever renames it, the PLAN fails
# loudly rather than the link going silently dead.
# =============================================================================

data "grafana_data_source" "traces" {
  name = "grafanacloud-${data.terraform_remote_state.observability.outputs.alerting_stack_slug}-traces"
}

resource "grafana_dashboard" "product_overview" {
  folder    = grafana_folder.dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "Product overview"
    uid           = "product-overview"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-6h", to = "now" }
    refresh       = "1m"
    tags          = ["products", "provisioned"]

    templating = {
      list = [
        {
          name       = "product"
          type       = "custom"
          label      = "product"
          query      = "rova,opshub,kb"
          includeAll = false
          multi      = false
          current    = { selected = true, text = "rova", value = "rova" }
        },
        {
          name       = "env"
          type       = "custom"
          label      = "environment"
          query      = "dev,prod"
          includeAll = false
          multi      = false
          current    = { selected = true, text = "prod", value = "prod" }
        },
      ]
    }

    # Product switcher (dashboards-gaps item 4, owner 2026-11-07): one
    # click per product, keeping the time range. keepTime carries from/to;
    # var-product sets this dashboard's own variable. Same trio on
    # Products (RED), MCP and Databases, so every shared surface answers
    # "does rova only have an MCP dashboard?" at a glance. concat, not a
    # mixed tuple: HCL has no separator between a literal object and a
    # following for-expression element.
    links = concat([
      {
        title       = "Trace search (Tempo, service.name=$product)"
        type        = "link"
        icon        = "compass"
        targetBlank = true
        # `urlencode()` encodes the `$` of `$product` as `%24`, and Grafana
        # interpolates dashboard variables on the RAW link string — `%24product`
        # is not a variable, so the link searched for a literal "$product".
        # Encode the JSON, then put `$` back. No `${...}` appears inside the
        # JSON, so `%7B`/`%7D` never need the same treatment here.
        url = "/explore?orgId=1&left=${replace(urlencode(jsonencode({
          datasource = { type = "tempo", uid = data.grafana_data_source.traces.uid }
          queries = [{
            refId     = "A"
            queryType = "traceql"
            query     = "{ resource.service.name =~ \"$product.*\" }"
          }]
          range = { from = "now-1h", to = "now" }
        })), "%24", "$")}"
      },
      ], [
      for p in ["rova", "opshub", "kb"] : {
        title       = p
        type        = "link"
        icon        = "bolt"
        targetBlank = false
        keepTime    = true
        url         = "/d/product-overview?orgId=1&var-product=${p}"
      }
    ])

    panels = [
      {
        id      = 1
        type    = "row"
        title   = "RED — inbound requests ($product / $env)"
        gridPos = { h = 1, w = 24, x = 0, y = 0 }
      },
      {
        id          = 2
        title       = "Request rate (req/s)"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 0, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { noValue = "no series — the request counter is not arriving" } }
        targets = [{
          expr         = "sum by (job) (rate(http_server_duration_milliseconds_count{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m]))"
          legendFormat = "{{job}}"
          refId        = "A"
        }]
      },
      {
        id          = 3
        title       = "5xx ratio"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 8, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit", min = 0, noValue = "no series" } }
        targets = [{
          expr = join("", [
            "(",
            "sum by (job) (rate(http_server_duration_milliseconds_count{status_class=\"5xx\", job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m]))",
            " or ",
            "sum by (job) (rate(http_server_duration_milliseconds_count{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 0",
            ") / ",
            "sum by (job) (rate(http_server_duration_milliseconds_count{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m]))",
          ])
          legendFormat = "{{job}}"
          refId        = "A"
        }]
      },
      {
        id          = 4
        title       = "p95 latency"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 16, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "ms", noValue = "no series" } }
        targets = [{
          expr         = "histogram_quantile(0.95, sum by (le, job) (rate(http_server_duration_milliseconds_bucket{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])))"
          legendFormat = "{{job}}"
          refId        = "A"
        }]
      },
      {
        id      = 5
        type    = "row"
        title   = "Scheduled work and queues"
        gridPos = { h = 1, w = 24, x = 0, y = 8 }
      },
      {
        id          = 6
        title       = "Job runs/min (job_name)"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 0, y = 9 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { noValue = "no job series — kb: none until a Celery task runs" } }
        targets = [{
          expr = join("", [
            "sum by (job, job_name) (rate(job_runs_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60",
            " or ",
            "sum by (job) (rate(celery_task_runs_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60",
          ])
          legendFormat = "{{job_name}} ({{job}})"
          refId        = "A"
        }]
      },
      {
        id          = 7
        title       = "Job failures/min"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 8, y = 9 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { min = 0, noValue = "none (or no job series)" } }
        targets = [{
          expr = join("", [
            "sum by (job, job_name) (rate(job_failures_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60",
            " or ",
            "sum by (job) (rate(celery_task_failures_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60",
          ])
          legendFormat = "{{job_name}} ({{job}})"
          refId        = "A"
        }]
      },
      {
        id          = 8
        title       = "Queue rows processed/min"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 16, y = 9 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { noValue = "no queue series for $product" } }
        targets = [{
          expr = join("", [
            "sum by (job, queue) (rate(queue_processed_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60",
            " or ",
            "sum by (job) (rate(celery_task_runs_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60",
          ])
          legendFormat = "{{job}} {{queue}}"
          refId        = "A"
        }]
      },
      # ── Second row of the queues/jobs question (dashboards-gaps item 5) ──
      # Same semantics on every app (shared platform lib, verified in source
      # 2026-11-07: packages/observability JobMetrics/QueueMetrics,
      # AbstractOutboxRelay, qnsc-kb-backend otel_metrics.py), so they are
      # rows on the ONE templated overview, not per-app dashboards.
      {
        id          = 23
        title       = "Job p95 duration (job_name)"
        description = "rova + opshub: job_duration_milliseconds (platform JobMetrics, opshub has 12 job_names, rova 2). kb: celery_task_duration_milliseconds in the same panel via `or` (kb's Celery beat now runs)."
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 0, y = 16 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "ms", noValue = "no job series for $product" } }
        targets = [{
          expr = join("", [
            "histogram_quantile(0.95, sum by (le, job, job_name) (rate(job_duration_milliseconds_bucket{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])))",
            " or ",
            "histogram_quantile(0.95, sum by (le, job) (rate(celery_task_duration_milliseconds_bucket{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])))",
          ])
          legendFormat = "{{job_name}} ({{job}})"
          refId        = "A"
        }]
      },
      {
        id          = 24
        title       = "Queue failures/min"
        description = "queue_failures_total{queue} (platform QueueMetrics.recordFailure; relay failures that also count a processed row are the relay panel below). kb has no queue series yet — its Celery tasks are the runs/failures panels above."
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 8, y = 16 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { min = 0, noValue = "none (or no queue series for $product)" } }
        targets = [{
          expr         = "sum by (job, queue) (rate(queue_failures_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60"
          legendFormat = "{{job}} {{queue}}"
          refId        = "A"
        }]
      },
      {
        id          = 25
        title       = "Queue lag p95 (seconds, by queue)"
        description = "queue.lag_seconds is a HISTOGRAM (QueueMetrics.recordLag — seconds since the oldest unclaimed row), so the quantile is over queue_lag_seconds_bucket. Rising lag = a relay stopped draining. kb: no queue series yet."
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 16, y = 16 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "s", min = 0, noValue = "no queue series for $product" } }
        targets = [{
          expr         = "histogram_quantile(0.95, sum by (le, job, queue) (rate(queue_lag_seconds_bucket{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])))"
          legendFormat = "{{job}} {{queue}}"
          refId        = "A"
        }]
      },
      {
        id          = 26
        title       = "Outbox relay pass failures/min"
        description = "outbox_relay_pass_failed_total{relay} (AbstractOutboxRelay — one series per relay when a whole relay pass threw). Sustained > 0 = the outbox-relay-failing alert territory."
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 0, y = 23 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { min = 0, noValue = "none (or no relay series for $product)" } }
        targets = [{
          expr         = "sum by (job, relay) (rate(outbox_relay_pass_failed_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60"
          legendFormat = "{{job}} {{relay}}"
          refId        = "A"
        }]
      },
      {
        id      = 27
        type    = "row"
        title   = "Security and auth"
        gridPos = { h = 1, w = 24, x = 0, y = 30 }
      },
      {
        id          = 28
        title       = "Logins/min by method and outcome"
        description = "auth_login_total{method, outcome} (platform AuthMetrics — SSO callback and dev-login). rova emits today; opshub shares the lib; empty for kb (team note — kb has no interactive login)."
        type        = "timeseries"
        gridPos     = { h = 7, w = 12, x = 0, y = 31 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { min = 0, noValue = "no login series for $product (rova today; kb: none by design)" } }
        targets = [{
          expr         = "sum by (method, outcome) (rate(auth_login_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60"
          legendFormat = "{{method}} {{outcome}}"
          refId        = "A"
        }]
      },
      {
        id          = 29
        title       = "Security events/min (by event)"
        description = "identity_security_events_total{event} (identity package — sign-in failures, lockouts, account replacement). rova emits today, opshub shares the lib; empty for kb (team note). Label is `event`, not `type` — source-verified 2026-11-07."
        type        = "timeseries"
        gridPos     = { h = 7, w = 12, x = 12, y = 31 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { min = 0, noValue = "no security-event series for $product" } }
        targets = [{
          expr         = "sum by (event) (rate(identity_security_events_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60"
          legendFormat = "{{event}}"
          refId        = "A"
        }]
      },
      {
        id          = 30
        title       = "Top security events (window)"
        description = "topk(5) increase over the dashboard's time range — the \"top types\" view of the same counter, for spotting which event dominates."
        type        = "stat"
        gridPos     = { h = 7, w = 12, x = 0, y = 38 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", noValue = "no security-event series for $product" } }
        targets = [{
          expr         = "topk(5, sum by (event) (increase(identity_security_events_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[$__range])))"
          legendFormat = "{{event}}"
          refId        = "A"
        }]
      },
      {
        id          = 31
        title       = "Failed logins (window)"
        description = "auth_login_total{outcome=\"failure\"} increase over the window — the failed-sign-in spike the identity alerts watch."
        type        = "stat"
        gridPos     = { h = 7, w = 12, x = 12, y = 38 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", noValue = "no login series for $product" } }
        targets = [{
          expr  = "sum(increase(auth_login_total{job=~\"$product/.+\", deployment_environment_name=\"$env\", outcome=\"failure\"}[$__range]))"
          refId = "A"
        }]
      },
      {
        id      = 9
        type    = "row"
        title   = "Dependencies and runtime"
        gridPos = { h = 1, w = 24, x = 0, y = 45 }
      },
      {
        id          = 10
        title       = "DB pool — in use"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 0, y = 46 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { min = 0, noValue = "no pool series (kb has none yet)" } }
        targets = [{
          expr         = "sum by (job) (db_pool_in_use{job=~\"$product/.+\", deployment_environment_name=\"$env\"})"
          legendFormat = "{{job}}"
          refId        = "A"
        }]
      },
      {
        id          = 11
        title       = "DB pool — waiting"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 8, y = 46 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { min = 0, noValue = "none waiting (or no pool series)" } }
        targets = [{
          expr         = "sum by (job) (db_pool_waiting{job=~\"$product/.+\", deployment_environment_name=\"$env\"})"
          legendFormat = "{{job}}"
          refId        = "A"
        }]
      },
      {
        id          = 12
        title       = "Node runtime — heap used / limit, event loop utilisation"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 16, y = 46 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { noValue = "no runtime series (Node products only)" } }
        targets = [
          {
            expr         = "sum by (job) (v8js_memory_heap_used_bytes{job=~\"$product/.+\", deployment_environment_name=\"$env\"})"
            legendFormat = "{{job}} heap used"
            refId        = "A"
          },
          {
            expr         = "sum by (job) (v8js_memory_heap_limit_bytes{job=~\"$product/.+\", deployment_environment_name=\"$env\"})"
            legendFormat = "{{job}} heap limit"
            refId        = "B"
          },
          {
            expr         = "max by (job) (nodejs_eventloop_utilization{job=~\"$product/.+\", deployment_environment_name=\"$env\"})"
            legendFormat = "{{job}} event loop (0-1)"
            refId        = "C"
          },
        ]
      },
      {
        id      = 13
        type    = "row"
        title   = "Logs and traces"
        gridPos = { h = 1, w = 24, x = 0, y = 53 }
      },
      {
        id         = 14
        title      = "Error log lines (namespace $product-$env)"
        type       = "logs"
        gridPos    = { h = 8, w = 24, x = 0, y = 54 }
        datasource = { type = "loki", uid = data.grafana_data_source.logs.uid }
        targets = [{
          # `level` is inside the JSON line on every product (rova/opshub:
          # `"level":"error"`, kb: `"level": "error"`), so a line regex covers
          # both without a JSON parser that would also have to match a shape.
          expr      = "{namespace=\"$product-$env\"} |~ \"level.{0,3}(error|critical|fatal)\""
          refId     = "A"
          queryType = "range"
        }]
        options = {
          showTime       = true
          sortOrder      = "Descending"
          wrapLogMessage = true
          dedupStrategy  = "none"
        }
      },
    ]
  })
}
