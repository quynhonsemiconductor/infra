# =============================================================================
# kb prod monitoring — the `kb-prod.tf` the P3 plan reserves for this lane
# (PLAN-P3-PROD-LAUNCH-2026-11-04 §2.3 P8). kb prod does NOT exist yet (no
# namespace, no pg-kb, no kb.qnsc.vn record), so everything here is gated on
# `kb_prod_live` (default false) — a plan/apply today shows nothing.
#
# AVAILABILITY
# readyz (Synthetic Monitoring) plus the shared Kubernetes rules, which carry
# kb-prod as a target from the same change: CrashLoopBackOff
# (onprem-workloads.tf), missing replicas (onprem-incident-20261103.tf) and
# failed Jobs (onprem-data-p0.tf). pg-kb lives in data-prod like
# pg-rova/pg-opshub, so the Postgres-not-Ready rule already matches its pods,
# and the CNPG backup/replication rules are prod-data-plane wide (see
# prod-cnpg-backup.tf and onprem-k3s.tf) — kb needs no copy of them.
#
# 5xx RULE: kb HAS one now, in prod-http-5xx.tf (`kb-prod-http-5xx-rate`),
# alongside rova/opshub. The older claim in this header — that no
# `http_server_*` series exist for any product and kb publishes only its
# in-process /metrics — was WRONG and is corrected here (audit S-H2):
# qnsc-kb-backend#369 exports the same `http.server.duration` family over
# OTLP, and the series ARE in Mimir. They are aggregated by Adaptive Metrics,
# so a bare `{__name__=~"http_server_.*"}` query returns nothing/422; query
# them `sum by (job,status_class,deployment_environment_name)`. The rule is
# silent until a kb prod API serves traffic (no_data_state = OK).
#
# SERIES PROVEN IN MIMIR (2026-11-05, G; datasource grafanacloud-qnsc-prom):
#   sum by (job, status_class, deployment_environment_name)
#     (increase(http_server_duration_milliseconds_count{job=~"kb/.+"}[7d]))
# returns ONE job, `kb/kb-api`, in `dev` with status_class 2xx = 15,090,
# 4xx = 7 and 5xx = 0 — so the `job=~"kb/.+"` prefix and the `status_class`
# label that prod-http-5xx.tf selects on do match the live series, not an
# assumed shape. No `prod` series exists yet because kb prod does not exist;
# that is exactly the case no_data_state = "OK" covers.
#
# ── GATE ───────────────────────────────────────────────────────────────────
# `kb_prod_live` is flipped by ONE PR in the kb prod window, after the SA's
# edge/tunnel PR puts kb.qnsc.vn behind Access with a /readyz bypass. Creating
# the check before the host resolves would page from the first probe.
# The check ALSO needs `uptime_checks_enabled` and the SM token because its
# probe comes from the data source (uptime-dev.tf:44-47) — the same expression
# there, so `.probes["Singapore"]` is indexed only when the data source exists.
#
# ── FLIP PROCEDURE (kb prod window, AFTER kb.qnsc.vn serves /readyz) ───────
#  0. Preconditions — all true before the flip PR is opened. They are the
#     go-live gates from sa-notes/reviews/kb-prod-readiness-2026-11-05.md §4.5:
#       a. SA's edge + tunnel apply is live: `dig +short kb.qnsc.vn` answers
#          the two Cloudflare edge IPs (it answers NOTHING before cutover) and
#          `curl -s https://kb.qnsc.vn/readyz` returns 200 with the compact
#          body {"status":"ready",...} through the Access bypass (`^/readyz$`).
#          A 302 to the Access login or an HTML body is NOT ready.
#       b. kb prod workloads serve in-cluster (api/worker/web Ready) and the
#          app is past warm-up — /readyz answers 503 while it warms.
#       c. `GRAFANA_SM_TOKEN` exists where the workflow reads it
#          (infra-plan.yml:425 for this stack's PR plan, infra-apply.yml:695
#          for apply-observability-alerting), and `uptime_checks_enabled`
#          stays true. With either missing, the check cannot arm; step 1's
#          guard now turns that into a FAILED plan instead of a silent no-op.
#  1. ONE PR: `kb_prod_live` default false -> true. Nothing else changes.
#     The precondition below is the half-apply guard — see its comment.
#  2. After the apply, verify in the window:
#       - SM check `kb-prod-readyz` (Singapore) is green; Mimir has
#         `probe_success{job="kb-prod-readyz"} > 0`.
#       - Rule group "kb (prod readyz)" exists and evaluates Normal.
#       - `kb-prod-http-5xx-rate` (prod-http-5xx.tf) stays silent
#         (no_data_state = OK) until the prod API serves >= 50 requests/10m;
#         it needs NO flip — it is already armed for every product/env.
#         Re-run the series proof at flip time if in doubt:
#         sum by (job,status_class,deployment_environment_name)
#           (increase(http_server_duration_milliseconds_count[1d]))
#         and expect a kb-api/prod row (the 2026-11-04 audit proved the same
#         query returns kb-api/dev; Adaptive Metrics 422s a bare
#         `{__name__=~"http_server_.*"}` query, so do not query that shape).
#  3. Rollback: revert the one word. The check and its rule are deleted; the
#     5xx rule and every shared Kubernetes rule are untouched.
#
# ORDERING, both ways. Flipping before the host resolves pages from the first
# probe (probe_success = 0, `for: 5m`). Flipping while the SM token is empty
# used to cull every resource and read as a green "no changes" plan — the
# guard below makes that mistake fail loudly instead.
#
# ── ROUTING ────────────────────────────────────────────────────────────────
# env=prod → grafana_notification_policy.root (Teams + devops@ email).
# =============================================================================

variable "kb_prod_live" {
  description = "Flip via a PR in the kb prod window (PLAN-P3 §2.3 P8) — the ONLY flip mechanism. Requires kb.qnsc.vn to resolve with a /readyz bypass; false = every resource below is culled."
  type        = bool
  default     = true # flipped 2026-11-05: kb.qnsc.vn live, /readyz 200 through the bypass
}

locals {
  kb_prod_live   = var.kb_prod_live
  kb_uptime_live = local.kb_prod_live && var.uptime_checks_enabled && var.grafana_sm_token != ""
}

# ── Synthetic Monitoring: kb prod readyz ───────────────────────────────────
# §12 budget: 5-minute check from ONE probe (Singapore) — ~8.64k
# executions/month. With rova prod (2 probes × 90 s), the two dev checks,
# opshub prod and this check the stack stays under the 100k free tier.
resource "grafana_synthetic_monitoring_check" "kb_prod_readyz" {
  count     = local.kb_uptime_live ? 1 : 0
  provider  = grafana.sm
  job       = "kb-prod-readyz"
  target    = "https://kb.qnsc.vn/readyz"
  frequency = 300000
  timeout   = 5000
  enabled   = true
  probes    = [data.grafana_synthetic_monitoring_probes.main[0].probes["Singapore"]]
  # No alert_sensitivity: SM legacy alerting is forbidden on new installations;
  # paging is the grafana_rule_group below on probe_success.

  labels = {
    product = "kb"
    env     = "prod"
  }

  settings {
    http {
      method = "GET"
      # kb serves /readyz as the alias of /health/ready (qnsc-kb-backend
      # src/api/main.py:1204-1207) and answers 200 with compact JSON. Assert
      # the body: a 200 alone can come from the SPA when routing is wrong, and
      # a 302 to the Access login also counts as an SM success without it.
      # Verified against the live dev twin on 2026-11-05:
      #   https://kb-dev.qnsc.vn/readyz ->
      #   {"status":"ready","database":"ok","redis":"ok","job_mode":"celery",
      #    "embedding":{"state":"ready","seconds":0.0},"degraded":false}
      # The matcher deliberately requires the exact compact form FastAPI
      # serializes; "ready" elsewhere in the body (e.g. "not_ready") does not
      # satisfy it.
      fail_if_body_not_matches_regexp = ["\"status\":\"ready\""]
    }
  }
}

resource "grafana_rule_group" "kb_prod_readyz_down" {
  # Gated on the FLAG, not on kb_uptime_live, so the precondition below is
  # evaluated whenever the flip happens. If it were gated on kb_uptime_live
  # too, a flip with the SM token empty would plan zero resources and exit
  # green — the one failure mode a flip PR must not have.
  count            = local.kb_prod_live ? 1 : 0
  name             = "kb (prod readyz)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  lifecycle {
    precondition {
      condition     = local.kb_uptime_live
      error_message = "kb_prod_live=true but the readyz check cannot arm: needs uptime_checks_enabled=true and a non-empty GRAFANA_SM_TOKEN (secret mapped to this stack in infra-plan.yml:425 and infra-apply.yml:695). Refusing to half-apply the flip."
    }
  }

  rule {
    name      = "kb-prod-readyz-down"
    condition = "B"
    for       = "5m"
    # The flag count gate above is the absent-target gate; once armed, a
    # VANISHED probe series (SM not publishing, check disabled outside tofu)
    # must page, not read as healthy. The precondition guarantees the check
    # exists whenever this rule exists.
    no_data_state  = "Alerting"
    exec_err_state = "Error"

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
        expr          = "probe_success{job=\"kb-prod-readyz\"}"
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
      product  = "kb"
      env      = "prod"
      severity = "critical"
    }

    annotations = {
      summary = "Synthetic check kb-prod-readyz failing: https://kb.qnsc.vn/readyz has returned non-2xx/3xx (or timed out, or not {\"status\":\"ready\"}) for 5 minutes."
    }
  }
}
