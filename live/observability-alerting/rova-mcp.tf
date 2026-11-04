# =============================================================================
# rova MCP — dashboard + write-spike alert.
#
# rova MCP v2 adds write tools behind the MCP_WRITES_ENABLED kill switch (dev
# first). By design there is NO separate MCP write rate limit — the per-person
# 60 MCP POSTs/min and the REST 100/min still apply — and this alert is the
# complementary control, because a runaway model retry loop is the failure mode
# those limits alone would let run until the cap.
#
# ── METRIC NAMES (verified against the LIVE series in Grafana Cloud, dev,
#    2026-11-04 — not from memory or the PR description) ──────────────────
# rova#878 created these OTel instruments (`apps/api/src/mcp/audit.ts`) and
# the Prometheus exporter renames them as follows:
#   mcp.tool.calls          -> mcp_tool_calls_total{tool, outcome}
#   mcp.tool.duration (ms)  -> mcp_tool_duration_milliseconds_{bucket,sum,count}{tool}
#   mcp.rate_limited        -> mcp_rate_limited_total            (counter, no labels)
# `mcp.tool.errors` (-> mcp_tool_errors_total{tool}) exists in the same file
# but had ZERO samples in the 7-day window examined, so the error-rate panel
# and the alert are built from mcp_tool_calls_total{outcome="error"} instead —
# that series is emitted on every call and was verified live.
#
# ── NO `env` LABEL ON THESE SERIES — THE JOIN IS DELIBERATE ─────────────────
# Verified live: the MCP series carry only cluster, instance, job="rova/rova-api",
# k8s_cluster_name, tool and outcome. The resource attributes that DO identify
# the environment (deployment_environment_name, service_namespace,
# k8s_namespace_name) reach Prometheus only on the `target_info` series — the
# collector does not convert resource attributes into metric labels. Both envs
# also share the same job label. So every env split below joins target_info on
# `instance`:
#     ... * on(instance) group_left(k8s_namespace_name) target_info
# This is verified working for prod (its live prod pod instance resolves to rova-prod) and
# returns empty for dev today (rova-dev has served no MCP call in the window).
# CAVEAT: the join depends on `instance` not being aggregated away. The
# Adaptive Metrics rules (live/adaptive-metrics) keep it intact for these
# metrics today; if a future rule aggregates instance for mcp_*, these panels
# and the rule go blind (NoData -> OK, so silent). Adding an env label at the
# collector is the durable fix and is NOT part of this change.
#
# ── WRITE TOOLS ────────────────────────────────────────────────────────────
# The regexp below is the v2.0 write catalogue's 14 tool names, by prefix; no
# read tool (current or planned) matches it. Keep it in step with the
# catalogue: a write tool renamed outside these prefixes stops counting as a
# write here.
#
# ── NOT GATED ──────────────────────────────────────────────────────────────
# No flag: the dashboard is inert until MCP data exists, and the rule cannot
# fire before the write tools ship (no series carries a write tool name yet).
# no_data_state = OK keeps the pre-v2 period silent, and exec_err_state =
# KeepLast stops a transient query error from fabricating a "resolved".
# =============================================================================

locals {
  mcp_write_tools = "rova_(create|update|add|plan|link|label|log|save|record|mark|delete).*"

  # Per-env identification, shared by every panel and both rules. See the
  # NO `env` LABEL note above for why this is a join and not a label selector.
  mcp_env_join = "on(instance) group_left(k8s_namespace_name) target_info"
}

resource "grafana_dashboard" "rova_mcp" {
  folder    = grafana_folder.rally_dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "rova MCP"
    uid           = "rova-mcp"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-24h", to = "now" }
    refresh       = "1m"
    tags          = ["rova", "mcp", "provisioned"]

    panels = [
      {
        id         = 1
        title      = "MCP calls by tool"
        type       = "timeseries"
        gridPos    = { h = 8, w = 12, x = 0, y = 0 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [{
          expr         = "sum by (tool) (rate(mcp_tool_calls_total[5m]))"
          legendFormat = "{{tool}}"
          refId        = "A"
        }]
      },
      {
        id          = 2
        title       = "MCP error rate, by env"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 12, y = 0 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit" } }
        # Same zero-fill shape as System Overview's error-rate panel: an
        # `or vector(0)` does not fill a MISSING group, so the error series is
        # re-derived zeroed from the (always present) request series per env.
        targets = [{
          expr = join("", [
            "(",
            "sum by (k8s_namespace_name) (rate(mcp_tool_calls_total{outcome=\"error\"}[5m]) * ${local.mcp_env_join})",
            " or ",
            "sum by (k8s_namespace_name) (rate(mcp_tool_calls_total[5m]) * ${local.mcp_env_join}) * 0",
            ")",
            " / ",
            "sum by (k8s_namespace_name) (rate(mcp_tool_calls_total[5m]) * ${local.mcp_env_join})",
          ])
          legendFormat = "{{k8s_namespace_name}}"
          refId        = "A"
        }]
      },
      {
        id          = 3
        title       = "MCP p95 duration, by env"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 0, y = 8 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "ms" } }
        targets = [{
          expr         = "histogram_quantile(0.95, sum by (le, k8s_namespace_name) (rate(mcp_tool_duration_milliseconds_bucket[5m]) * ${local.mcp_env_join}))"
          legendFormat = "{{k8s_namespace_name}}"
          refId        = "A"
        }]
      },
      {
        id         = 4
        title      = "MCP rate-limit refusals"
        type       = "stat"
        gridPos    = { h = 8, w = 6, x = 12, y = 8 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [{
          expr  = "sum(increase(mcp_rate_limited_total[$__range]))"
          refId = "A"
        }]
      },
      {
        id         = 5
        title      = "MCP writes vs reads, by env"
        type       = "timeseries"
        gridPos    = { h = 8, w = 6, x = 18, y = 8 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [
          {
            expr         = "sum by (k8s_namespace_name) (rate(mcp_tool_calls_total{tool=~\"${local.mcp_write_tools}\"}[5m]) * ${local.mcp_env_join})"
            legendFormat = "writes {{k8s_namespace_name}}"
            refId        = "A"
          },
          {
            expr         = "sum by (k8s_namespace_name) (rate(mcp_tool_calls_total{tool!~\"${local.mcp_write_tools}\"}[5m]) * ${local.mcp_env_join})"
            legendFormat = "reads {{k8s_namespace_name}}"
            refId        = "B"
          },
        ]
      },
    ]
  })
}

# ── write-spike alert, one rule per env ────────────────────────────────────
# Threshold 30 write calls / 10 min (≈ 3/min) per env, sustained `for: 5m`.
# One-line reason: dogfooding is a few writes per person per day and each
# bulk action is ONE call (a 25-item plan, a 20-result run), so ~3/min is far
# outside normal use while sitting 20× under one person's 60/min MCP cap — it
# catches a runaway retry loop early instead of after the cap is drained.
#
# Two rules, not one grouped rule: the metric has no env label, so each rule
# filters on its own namespace through the join above, and carries the env
# label the notification policy routes on (prod -> Teams via the root policy;
# dev -> Teams only via the opt-in `paging = "teams"` child).
resource "grafana_rule_group" "rova_mcp_write_spike_dev" {
  name             = "rova mcp (writes — dev)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "rova-mcp-write-spike-dev"
    condition      = "B"
    for            = "5m"
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
          "sum(",
          "  increase(mcp_tool_calls_total{tool=~\"${local.mcp_write_tools}\"}[10m])",
          "  and on(instance) target_info{k8s_namespace_name=\"rova-dev\"}",
          ")",
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
              params = [30]
            }
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    labels = {
      product  = "rova"
      env      = "development" # matches the notification policy matcher, NOT "dev"
      paging   = "teams"
      severity = "warning"
    }

    annotations = {
      summary     = "rova dev: more than 30 MCP write calls in 10 minutes (≈3/min, sustained 5m). Normal dogfooding is a few writes per person per day — suspect a runaway model retry loop. Check the rova MCP dashboard's writes-vs-reads panel and the mcp.tool_call audit lines before raising MCP_WRITES_ENABLED further."
      description = "sum(increase(mcp_tool_calls_total{tool=~write catalogue}[10m])) for namespace rova-dev is above 30."
    }
  }
}

resource "grafana_rule_group" "rova_mcp_write_spike_prod" {
  name             = "rova mcp (writes — prod)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "rova-mcp-write-spike-prod"
    condition      = "B"
    for            = "5m"
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
          "sum(",
          "  increase(mcp_tool_calls_total{tool=~\"${local.mcp_write_tools}\"}[10m])",
          "  and on(instance) target_info{k8s_namespace_name=\"rova-prod\"}",
          ")",
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
              params = [30]
            }
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    labels = {
      product  = "rova"
      env      = "production" # matches the notification policy matcher, NOT "prod"
      severity = "warning"
    }

    annotations = {
      summary     = "rova prod: more than 30 MCP write calls in 10 minutes (≈3/min, sustained 5m). If this is not a planned bulk action, suspect a runaway model retry loop; reconcile the mcp.tool_call audit lines (who, which target keys) before any further writes."
      description = "sum(increase(mcp_tool_calls_total{tool=~write catalogue}[10m])) for namespace rova-prod is above 30."
    }
  }
}
