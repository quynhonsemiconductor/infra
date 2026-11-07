# =============================================================================
# MCP — ONE templated dashboard + rova's write-spike alert.
#
# ── DASHBOARD (dashboards-gaps item 2, owner 2026-11-07) ───────────────────
# Was "rova MCP", a per-product copy. Now ONE dashboard templated by
# `var product` (rova|opshub|kb) over the same mcp_* metrics, living in
# QNSC/Dashboards (item 4) next to the other shared surfaces.
#
#   WHICH PRODUCTS EMIT TODAY: rova only (verified live 2026-11-04, see the
#   metric-names block below). opshub shares the platform lib but does not
#   serve /mcp yet; kb has none. Every panel says so, so an empty panel reads
#   as "expected until <product> serves /mcp", not as a broken query.
#
#   UID: kept as `rova-mcp` on purpose. Grafana has no dashboard redirect, and
#   the uid is what bookmarks and chat links carry — same uid on the new
#   templated dashboard keeps every existing link working while the title and
#   location change. (The resource name stays `grafana_dashboard.rova_mcp`
#   for the same reason: renaming it would delete + recreate in state for no
#   benefit.)
#
# ── rova MCP v2 writes ─────────────────────────────────────────────────────
# rova MCP v2 adds write tools behind the MCP_WRITES_ENABLED kill switch (dev
# first). By design there is NO separate MCP write rate limit — the per-person
# 60 MCP POSTs/min and the REST 100/min still apply — and the write-spike alert
# below is the complementary control, because a runaway model retry loop is the
# failure mode those limits alone would let run until the cap. The alert stays
# rova-scoped (it filters the rova write catalogue and routes by env), unlike
# the dashboard, which is templated.
#
# ── METRIC NAMES (verified against the LIVE series in Grafana Cloud, dev,
#    2026-11-04 — not from memory or the PR description; re-checked in source
#    2026-11-07, apps/api/src/mcp/audit.ts) ─────────────────────────────────
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
# ── `env` LABEL (gitops#242) ───────────────────────────────────────────────
# Earlier this dashboard joined `target_info` on `instance`, because the MCP
# series carried no environment and both envs share job="rova/rova-api". The
# durable fix landed in gitops platform/alloy (`env-label` data processor): the
# collector now copies the `deployment.environment.name` resource attribute onto
# the app metric datapoints, so the series carry `env="dev"|"prod"` directly and
# every panel groups by `env` with no join.
#
# ORDERING: until that collector change is synced, the label does not exist. The
# panels then collapse to one unlabelled series (harmless), and the alert —
# which filters on the label — has no series and stays OK (no_data_state).
# Verify with `count by (env) (mcp_tool_calls_total)` before relying on it.
#
# Adaptive Metrics aggregates labels that are not in a rule's `keep_labels`, and
# no rule covers `mcp_*` today, so `env` survives here. If an `mcp_*` rule is
# added later it MUST keep `env`, or these panels and the alert go blind.
#
# ── WRITE TOOLS ────────────────────────────────────────────────────────────
# The regexp below is the v2.0 write catalogue's 14 tool names, by prefix; no
# read tool (current or planned) matches it. Keep it in step with the
# catalogue: a write tool renamed outside these prefixes stops counting as a
# write here. It is a rova catalogue; the templated dashboard keeps the
# writes-vs-reads panel for rova only in its description text.
#
# ── NOT GATED ──────────────────────────────────────────────────────────────
# No flag: the dashboard is inert until MCP data exists, and the rule cannot
# fire before the write tools ship (no series carries a write tool name yet).
# no_data_state = OK keeps the pre-v2 period silent, and exec_err_state =
# KeepLast stops a transient query error from fabricating a "resolved".
# =============================================================================

locals {
  mcp_write_tools = "rova_(create|update|add|plan|link|label|log|save|record|mark|delete).*"

  # One sentence, reused on every panel: says who emits today so an empty
  # panel reads as expected, not broken (dashboards-gaps item 2).
  mcp_emitters = "rova emits these series today (verified 2026-11-04). opshub shares the platform lib but does not serve /mcp yet, and kb has none — no data until that product serves /mcp."
}

resource "grafana_dashboard" "rova_mcp" {
  # Kept in QNSC/Dashboards (item 4: shared, templated — not a rova-folder
  # copy), with the `rova-mcp` uid so existing bookmarks keep working.
  folder    = grafana_folder.dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "MCP"
    uid           = "rova-mcp"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-24h", to = "now" }
    refresh       = "1m"
    tags          = ["mcp", "products", "provisioned"]

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

    # Product switcher (item 4): one click moves the WHOLE dashboard to that
    # product's view, keeping the time range. `keepTime` carries from/to;
    # `var-product` sets the template variable.
    links = [
      for p in ["rova", "opshub", "kb"] : {
        title       = p
        type        = "link"
        icon        = "bolt"
        targetBlank = false
        keepTime    = true
        url         = "/d/rova-mcp?orgId=1&var-product=${p}"
      }
    ]

    panels = [
      {
        id          = 1
        title       = "MCP calls by tool"
        description = local.mcp_emitters
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 0, y = 0 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { noValue = "no series — $product does not serve /mcp yet (rova only today)" } }
        targets = [{
          expr         = "sum by (tool) (rate(mcp_tool_calls_total{job=~\"$product/.+\", env=\"$env\"}[5m]))"
          legendFormat = "{{tool}}"
          refId        = "A"
        }]
      },
      {
        id          = 2
        title       = "MCP error rate, by env"
        description = local.mcp_emitters
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 12, y = 0 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit", noValue = "no series — $product does not serve /mcp yet (rova only today)" } }
        # Same zero-fill shape as System Overview's error-rate panel: an
        # `or vector(0)` does not fill a MISSING group, so the error series is
        # re-derived zeroed from the (always present) request series per env.
        targets = [{
          expr = join("", [
            "(",
            "sum by (env) (rate(mcp_tool_calls_total{outcome=\"error\", job=~\"$product/.+\", env=\"$env\"}[5m]))",
            " or ",
            "sum by (env) (rate(mcp_tool_calls_total{job=~\"$product/.+\", env=\"$env\"}[5m])) * 0",
            ")",
            " / ",
            "sum by (env) (rate(mcp_tool_calls_total{job=~\"$product/.+\", env=\"$env\"}[5m]))",
          ])
          legendFormat = "{{env}}"
          refId        = "A"
        }]
      },
      {
        id          = 3
        title       = "MCP p95 duration, by env"
        description = local.mcp_emitters
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 0, y = 8 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "ms", noValue = "no series — $product does not serve /mcp yet (rova only today)" } }
        targets = [{
          expr         = "histogram_quantile(0.95, sum by (le, env) (rate(mcp_tool_duration_milliseconds_bucket{job=~\"$product/.+\", env=\"$env\"}[5m])))"
          legendFormat = "{{env}}"
          refId        = "A"
        }]
      },
      {
        id          = 4
        title       = "MCP rate-limit refusals"
        description = local.mcp_emitters
        type        = "stat"
        gridPos     = { h = 8, w = 6, x = 12, y = 8 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [{
          expr  = "sum(increase(mcp_rate_limited_total{job=~\"$product/.+\", env=\"$env\"}[$__range]))"
          refId = "A"
        }]
      },
      {
        id          = 5
        title       = "MCP writes vs reads, by env"
        description = "${local.mcp_emitters} The write/read split is the rova v2 write catalogue — a rova-specific tool-name prefix list; for other products every call reads as a read."
        type        = "timeseries"
        gridPos     = { h = 8, w = 6, x = 18, y = 8 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [
          {
            expr         = "sum by (env) (rate(mcp_tool_calls_total{job=~\"$product/.+\", env=\"$env\", tool=~\"${local.mcp_write_tools}\"}[5m]))"
            legendFormat = "writes {{env}}"
            refId        = "A"
          },
          {
            expr         = "sum by (env) (rate(mcp_tool_calls_total{job=~\"$product/.+\", env=\"$env\", tool!~\"${local.mcp_write_tools}\"}[5m]))"
            legendFormat = "reads {{env}}"
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
# Two rules, not one grouped rule: each selects its own metrics with
# `env="dev"` / `env="prod"` and carries the `env` RULE label the notification
# policy routes on (prod -> Teams via the root policy; dev -> Teams only via
# the opt-in `paging = "teams"` child).
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
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "sum(increase(mcp_tool_calls_total{tool=~\"${local.mcp_write_tools}\", env=\"dev\"}[10m]))"
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
      env      = "dev" # matches the notification policy matcher, NOT "dev"
      paging   = "teams"
      severity = "warning"
    }

    annotations = {
      summary     = "rova dev: more than 30 MCP write calls in 10 minutes (≈3/min, sustained 5m). Normal dogfooding is a few writes per person per day — suspect a runaway model retry loop. Check the rova MCP dashboard's writes-vs-reads panel and the mcp.tool_call audit lines before raising MCP_WRITES_ENABLED further."
      description = "sum(increase(mcp_tool_calls_total{tool=~write catalogue}[10m])) for env=dev is above 30."
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
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "sum(increase(mcp_tool_calls_total{tool=~\"${local.mcp_write_tools}\", env=\"prod\"}[10m]))"
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
      env      = "prod"
      severity = "warning"
    }

    annotations = {
      summary     = "rova prod: more than 30 MCP write calls in 10 minutes (≈3/min, sustained 5m). If this is not a planned bulk action, suspect a runaway model retry loop; reconcile the mcp.tool_call audit lines (who, which target keys) before any further writes."
      description = "sum(increase(mcp_tool_calls_total{tool=~write catalogue}[10m])) for env=prod is above 30."
    }
  }
}
