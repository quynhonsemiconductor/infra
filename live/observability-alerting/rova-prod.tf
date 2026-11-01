# =============================================================================
# rova prod monitoring — CUTOVER-2026-11 Stage D prerequisite (cutover
# ≈ 2026-11-10; D5's gate reads "Synthetic green"). Hosted in
# `observability-alerting` — the plan's home for alerting-as-code (§12:
# "Grafana Alerting → Teams (prod) + devops@qnsc.vn, as code in
# observability-alerting") — alongside the shared providers/variables in
# monitoring-providers.tf, which this PR carries identically to the opshub PR
# (#210) so the two merge cleanly in either order.
#
# rova's checks exist NOWHERE in code today (neither here, in `observability`,
# nor in any module) — the AWS-era estate had no Terraform for them. §12 is
# the specification this file implements; the Schedules section cites the
# exact plan lines.
#
# TWO GATES, split 2026-11-01 (fast track: rova prod leaves AWS in 1–2 days).
#   * the PROD READYZ check + rule arm on `uptime_checks_enabled`
#     (uptime-dev.tf) — the flag the fast-track PR turns on, together with the
#     dev checks. The SM probe id comes from the probes data source.
#   * the BACKUP checks arm on `rova_prod_live`, flipped by ONE one-word PR in
#     the Stage D window once Healthchecks channel UUIDs exist. There is
#     deliberately NO CI variable for that flag — a repo variable would flip
#     three alert resources past review.
# A plan with both flags false shows NOTHING.
#
# ── HOW THE JOBS PING (read before wiring CronJobs) ──────────────────────────
# Jobs ping by PROJECT PING KEY + SLUG, never by check UUID:
#     https://hc-ping.com/<ping-key>/<slug>
# The ping key lives ONLY in `kv-qnsc-prod` and reaches the batch CronJobs via
# ESO (§7.1) — never in Git, never in tofu. THE REASON: in healthchecksio
# v2.3.0 the resource's `id` and `ping_url` are NOT sensitive, and Healthchecks
# keeps ACCEPTING pings on the check UUID even when jobs ping by ping-key +
# slug — so a UUID reaching plan.txt, the Actions log or the PR plan comment
# WOULD publish a working ping URL. Two controls make that impossible: every
# check pins its `slug` (deterministic, no UUID in the ping path jobs use),
# and the observability-alerting plan/apply jobs in infra-plan.yml /
# infra-apply.yml pipe all tofu output through a UUID redactor before it hits
# plan.txt/apply.txt, the logs, or the PR plan comment. Never weaken either.
#
# ── SCHEDULES (plan §10.2, §10.3, §10.4, §12) ────────────────────────────────
# dump        01:30 daily   (§10.2: batch runs one job at a time; opshub +15 min)
# restore     Sun 04:00     (§10.4: ONE sequential job, rova pass then opshub
#                            pass; THIS check pings on the FIRST pass)
# azure copy  Sun 03:00     (§10.3)
#
# ── FLIP PROCEDURE (Stage D, gated on the prod-move apply) ──────────────────
#  1. Owner adds repo secrets GRAFANA_SM_TOKEN (SM API token from the stack's
#     Synthetic Monitoring page — NOT GRAFANA_CLOUD_API_KEY) and
#     HEALTHCHECKS_API_TOKEN. The workflow mappings already exist (scoped to
#     this stack: infra-plan.yml matrix, apply-observability-alerting).
#  2. One PR: rova_prod_live → true and healthchecks_channel_ids → the Teams +
#     devops@ channel UUIDs. The lifecycle preconditions below make the plan
#     FAIL if the channels are missing, so the flip cannot half-apply. (The
#     readyz check is already armed by the fast-track flag; sm_probe_id is no
#     longer used — the probe comes from the SM API data source.)
#  3. Stage D's gates read these checks: Synthetic green (D5) and the restore
#     pass green (§10.4) before any announcement.
#
# NOTE ON THE SM ALERT ROUTE: alert_sensitivity creates no rules by itself and
# SM check labels do not become alert labels — the real alert is the
# flag-gated grafana_rule_group below (probe_success == 0 for 5m, rule labels
# env=production + product=rova), routed by grafana_notification_policy.root
# (Teams for prod, devops@ always) — §12's routing.
# =============================================================================

variable "rova_prod_live" {
  description = "Flip via a PR changing this default in the Stage D window (CUTOVER-2026-11, ≈ 2026-11-10) — the ONLY flip mechanism. false = every resource below is culled and plans show nothing."
  type        = bool
  default     = false
}

locals {
  rova_live = var.rova_prod_live

  # UPTIME IS ARMED SEPARATELY (2026-11-01, fast track: rova prod leaves AWS in
  # 1–2 days). The prod readyz check and its rule no longer wait for the full
  # Stage-D flip: they follow `uptime_checks_enabled` (uptime-dev.tf), which also
  # arms the dev checks. The BACKUP checks below still wait for `rova_prod_live`
  # because they need Healthchecks channel ids and a real CronJob to ping.
  #
  # Gated on the SM token as well as the flag: with no token the aliased provider
  # cannot configure, and ANY instance (the probe data source included) would
  # fail the plan. `count` keeps the data source out of the graph too.
  uptime_live = var.uptime_checks_enabled && var.grafana_sm_token != ""
}

# The rova-prod slot of §12's SIX-check budget (rova+opshub prod+dev, kb-dev,
# + one spare) — this PR fills a budgeted slot, it does not grow it. 5-minute
# HTTP GET per §12. alert_sensitivity = "high" records sensitivity on the SM
# side; the ALERT itself is the flag-gated rule group below.
resource "grafana_synthetic_monitoring_check" "rova_prod_readyz" {
  count = local.uptime_live ? 1 : 0
  # the grafana.sm alias never configures while count is 0 (no instances)
  provider  = grafana.sm
  job       = "rova-prod-readyz"
  target    = "https://rova.qnsc.vn/readyz"
  frequency = 300000 # ms — every 5 min, §12
  timeout   = 5000   # ms — validate against the SM API's cap in the flip PR
  enabled   = true
  # The probe id comes from the SM API through the data source (uptime-dev.tf),
  # not from a hand-set variable: the fast track cannot wait for a human to read
  # a number out of the UI. One public probe, "Frankfurt" — §12 caps the estate
  # at one probe, and a fixed name keeps the choice reviewable in git.
  probes            = [data.grafana_synthetic_monitoring_probes.main[0].probes["Frankfurt"]]
  alert_sensitivity = "high"

  labels = {
    product = "rova"
    env     = "production" # matches notification policy matcher, NOT "prod"
  }

  settings {
    http {
      method = "GET"
    }
  }
}

# ── Synthetic Monitoring alert rule ─────────────────────────────────────────
# §12's prod routing as code: fires when the check's probe reports failure
# (probe_success == 0) for 5 minutes. Rule labels env=production + product=rova
# route it through grafana_notification_policy.root — Teams for prod, devops@
# always — the same policy every other rule in this stack uses. Same datasource
# (the stack's managed Prometheus, where SM publishes probe_success) as
# series_near_cap in main.tf.
resource "grafana_rule_group" "rova_prod_readyz_down" {
  count            = local.uptime_live ? 1 : 0
  name             = "rova (prod readyz)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  rule {
    name           = "rova-prod-readyz-down"
    condition      = "B"
    for            = "5m"
    no_data_state  = "OK"
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
        expr          = "probe_success{job=\"rova-prod-readyz\"}"
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
      product  = "rova"
      env      = "production" # matches the notification policy matcher, NOT "prod"
      severity = "critical"
    }

    annotations = {
      summary = "Synthetic check rova-prod-readyz failing: https://rova.qnsc.vn/readyz has returned non-2xx/3xx (or timed out) from the SM probe for 5 minutes (§12)."
    }
  }
}

# ── Healthchecks.io — the batch-job pings (§12 external row) ────────────────
# Providers live in monitoring-providers.tf (shared with opshub-prod.tf).

# Nightly pg_dump of pg-rova → R2 dumps/pg-rova/daily/ (§10.2: 01:30).
# Grace 2 h ≈ §12's "Dump > 26 h" alert. Ping: /start then success (or /fail)
# from the CronJob, by ping key + slug (see header — never by the UUID this
# resource's id/ping_url carry).
resource "healthchecksio_check" "rova_prod_dump" {
  count    = local.rova_live ? 1 : 0
  name     = "rova-prod-dump"
  slug     = "rova-prod-dump"
  tags     = ["rova", "prod", "backup"]
  desc     = "Nightly pg_dump -Fc of pg-rova (ONPREM-PLAN §10.2). Ping /start, then success or /fail. Ping key: kv-qnsc-prod via ESO."
  channels = var.healthchecks_channel_ids
  schedule = "30 1 * * *"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 7200

  lifecycle {
    precondition {
      condition     = length(var.healthchecks_channel_ids) > 0
      error_message = "healthchecks_channel_ids is empty — the flip PR must set the Teams + devops@ channel UUIDs (§12 routing)."
    }
  }
}

# Weekly restore test, FIRST pass (§10.4: ONE Sun 04:00 job, rova pass then
# opshub pass — batch runs one job at a time; this check pings on the rova
# pass). Schedule at the job start, 04:00; grace 45 MIN (§10.4: "running >
# 45 min" per pass). The job pings /start at the beginning of its rova pass,
# success or /fail at the end — /start makes the over-run alert the job's own
# responsibility; this check covers "failed or missed".
resource "healthchecksio_check" "rova_prod_restore" {
  count    = local.rova_live ? 1 : 0
  name     = "rova-prod-restore"
  slug     = "rova-prod-restore"
  tags     = ["rova", "prod", "restore-test"]
  desc     = "Sun 04:00 restore test, pg-rova pass (first sequential pass; ONPREM-PLAN §10.4). Ping /start on pass start, success or /fail at end. Ping key: kv-qnsc-prod via ESO."
  channels = var.healthchecks_channel_ids
  schedule = "0 4 * * 0"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 2700 # 45 min, §10.4

  lifecycle {
    precondition {
      condition     = length(var.healthchecks_channel_ids) > 0
      error_message = "healthchecks_channel_ids is empty — the flip PR must set the Teams + devops@ channel UUIDs (§12 routing)."
    }
  }
}

# Sunday Azure Blob copy of the pg-rova dumps (§10.3: weekly, locked 14 d;
# rova's slot is 03:00 Sunday — opshub staggers +15 min).
# Grace 1 d on the weekly schedule ≈ §12's "Azure copy > 8 d" alert.
resource "healthchecksio_check" "rova_prod_azure_copy" {
  count    = local.rova_live ? 1 : 0
  name     = "rova-prod-azure-copy"
  slug     = "rova-prod-azure-copy"
  tags     = ["rova", "prod", "backup", "azure"]
  desc     = "Sunday copy of pg-rova dumps to Azure Blob, locked 14 d (ONPREM-PLAN §10.3). Ping success or /fail. Ping key: kv-qnsc-prod via ESO."
  channels = var.healthchecks_channel_ids
  schedule = "0 3 * * 0"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 86400

  lifecycle {
    precondition {
      condition     = length(var.healthchecks_channel_ids) > 0
      error_message = "healthchecks_channel_ids is empty — the flip PR must set the Teams + devops@ channel UUIDs (§12 routing)."
    }
  }
}
