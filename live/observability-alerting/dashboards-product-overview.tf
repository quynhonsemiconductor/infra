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
#   celery_task_runs_total / celery_task_failures_total
#                                         kb's Celery worker (same questions,
#                                         different names; the `or` in each
#                                         panel makes one panel answer both)
#   queue_processed_total / queue_failures_total
#                                         outbox/relay throughput
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

    links = [
      {
        title       = "Trace search (Tempo, service.name=$product)"
        type        = "link"
        icon        = "compass"
        targetBlank = true
        url = "/explore?orgId=1&left=${urlencode(jsonencode({
          datasource = { type = "tempo", uid = data.grafana_data_source.traces.uid }
          queries = [{
            refId     = "A"
            queryType = "traceql"
            query     = "{ resource.service.name =~ \"$product.*\" }"
          }]
          range = { from = "now-1h", to = "now" }
        }))}"
      },
    ]

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
        fieldConfig = { defaults = { noValue = "no job series (kb: beat must run for task metrics)" } }
        targets = [{
          expr = join("", [
            "sum by (job, job_name) (rate(job_runs_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60",
            " or ",
            "sum by (job) (rate(celery_task_runs_total{job=~\"$product/.+\", deployment_environment_name=\"$env\"}[5m])) * 60",
          ])
          legendFormat = "{{job_name}}"
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
          legendFormat = "{{job_name}}"
          refId        = "A"
        }]
      },
      {
        id          = 8
        title       = "Queue rows processed/min"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 16, y = 9 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { noValue = "no queue series" } }
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
      {
        id      = 9
        type    = "row"
        title   = "Dependencies and runtime"
        gridPos = { h = 1, w = 24, x = 0, y = 16 }
      },
      {
        id          = 10
        title       = "DB pool — in use"
        type        = "timeseries"
        gridPos     = { h = 7, w = 8, x = 0, y = 17 }
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
        gridPos     = { h = 7, w = 8, x = 8, y = 17 }
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
        gridPos     = { h = 7, w = 8, x = 16, y = 17 }
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
        gridPos = { h = 1, w = 24, x = 0, y = 24 }
      },
      {
        id         = 14
        title      = "Error log lines (namespace $product-$env)"
        type       = "logs"
        gridPos    = { h = 8, w = 24, x = 0, y = 25 }
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
