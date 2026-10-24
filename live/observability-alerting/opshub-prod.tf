# =============================================================================
# opshub prod monitoring (H-D23) — CUTOVER-2026-11 Stage D2 prerequisite.
# Hosted in `observability-alerting` — the plan's home for alerting-as-code
# (§12: "Grafana Alerting → Teams (prod) + devops@qnsc.vn, as code in
# observability-alerting"), and the one of the two Grafana stacks that plans
# and applies today. The SM/HC providers and shared variables live in
# monitoring-providers.tf; with zero live resource instances tofu never
# configures those clients — the same rule the two-stack split relies on.
#
# DISABLED UNTIL CUTOVER. Every resource is `count = var.opshub_prod_live ? 1 : 0`,
# so a plan today shows NOTHING (and the nightly drift job sees nothing — this
# stack is in its list). ONE flip mechanism: a one-word PR that changes the
# `opshub_prod_live` default to `true` in the D2 window, SA-reviewed like any
# change, which also sets `sm_probe_id` (default null; the SM probe id is only
# knowable with a live SM token) and the Healthchecks channel UUIDs. There is
# deliberately NO CI variable for the flag — a repo variable would flip five
# alert resources past review.
#
# ── HOW THE JOBS PING (read before wiring CronJobs) ──────────────────────────
# Jobs ping by PROJECT PING KEY + SLUG, never by check UUID:
#     https://hc-ping.com/<ping-key>/<slug>
# The ping key lives ONLY in `kv-qnsc-prod` and reaches the batch CronJobs via
# ESO (§7.1) — never in Git, never in tofu. THE REASON: in healthchecksio
# v2.3.0 the resource's `id` and `ping_url` are NOT sensitive, so this stack's
# plan/apply output in public Actions logs would otherwise publish a working
# ping URL. Slug-based pings make every tofu-computed value publishable:
# nothing in tofu output needs to be secret. That is also why every check
# below pins its `slug` explicitly instead of letting the provider derive one.
#
# ── SCHEDULES (plan §10.2, §10.3, §10.4, §12 — opshub = rova's slots +15 min) ─
# dump        01:45 daily   (§10.2: rova 01:30, batch runs one job at a time)
# restore     Sun 04:00     (§10.4: ONE sequential job, rova pass then opshub
#                            pass; this check pings on the SECOND pass)
# azure copy  Sun 03:15     (§10.3: rova 03:00 Sunday)
# door-term   every 5 min   (ADR ATTENDANCE-DEVICE §4)
#
# ── FLIP PROCEDURE (Stage D2, gated on D2.4's `live/edge` apply) ─────────────
#  1. Owner adds repo secrets GRAFANA_SM_TOKEN (SM API token from the stack's
#     Synthetic Monitoring page — NOT GRAFANA_CLOUD_API_KEY) and
#     HEALTHCHECKS_API_TOKEN. The workflow mappings already exist, scoped to
#     this stack only (infra-plan.yml plan matrix, apply-observability-alerting).
#  2. One PR: opshub_prod_live → true, sm_probe_id → Frankfurt's id
#     (GET <sm_url>/api/v1/probes with the SM token), healthchecks_channel_ids →
#     the Teams + devops@ channel UUIDs. The lifecycle preconditions below make
#     the plan FAIL if any of these is missing, so the flip cannot half-apply.
#  3. D2.6 uses opshub-prod-dump + opshub-prod-restore as the exit gate.
#
# NOTE ON THE SM ALERT ROUTE: alert_sensitivity = "high" turns on SM's managed
# alerts for the check; its labels (product=opshub, env=production) match the
# existing grafana_notification_policy.root child policy here (env=production →
# Teams + devops@), which is §12's routing. No new contact point or rule.
# =============================================================================

variable "opshub_prod_live" {
  description = "Flip via a PR changing this default in the Stage D2 window (CUTOVER-2026-11) — the ONLY flip mechanism. false = every resource below is culled and plans show nothing."
  type        = bool
  default     = false
}

locals {
  opshub_live = var.opshub_prod_live
}

# ── Synthetic Monitoring ────────────────────────────────────────────────────
# The aliased grafana.sm and healthchecksio providers live in
# monitoring-providers.tf (shared with rova-prod.tf). Alert routing: §12's
# existing pipeline — grafana_notification_policy.root in main.tf sends
# env=production to Teams + devops@. No new contact point or rule.

# The opshub-prod slot of §12's SIX-check budget (rova+opshub prod+dev, kb-dev,
# + one spare) — this PR fills a budgeted slot, it does not grow it. 5-minute
# HTTP GET per §12. /readyz has no Access on opshub prod (§8.2: "no Access on
# prod"). alert_sensitivity = "high" + these labels route the managed alert
# through grafana_notification_policy.root (env=production → Teams + devops@).
resource "grafana_synthetic_monitoring_check" "opshub_prod_readyz" {
  count = local.opshub_live ? 1 : 0
  # the sm alias never configures while count is 0 (no instances)
  provider          = grafana.sm
  job               = "opshub-prod-readyz"
  target            = "https://opshub.qnsc.vn/readyz"
  frequency         = 300000 # ms — every 5 min, §12
  timeout           = 5000   # ms — validate against the SM API's cap in the flip PR
  enabled           = true
  probes            = [var.sm_probe_id]
  alert_sensitivity = "high"

  labels = {
    product = "opshub"
    env     = "production" # matches notification policy matcher, NOT "prod"
  }

  settings {
    http {
      method = "GET"
    }
  }

  lifecycle {
    precondition {
      condition     = var.sm_probe_id != null
      error_message = "sm_probe_id is null — the flip PR must set it (GET <sm_url>/api/v1/probes with GRAFANA_SM_TOKEN; §12 caps at 1 probe)."
    }
  }
}

# ── Healthchecks.io — the batch-job pings (§12 external row) ────────────────

# Nightly pg_dump of pg-opshub → R2 dumps/pg-opshub/daily/ (§10.2: 01:45 =
# rova's 01:30 slot + 15 min). Grace 2 h ≈ §12's "Dump > 26 h" alert.
# Ping: /start then success (or /fail) from the CronJob, by ping key + slug
# (see header — never by the UUID this resource's id/ping_url carry).
resource "healthchecksio_check" "opshub_prod_dump" {
  count    = local.opshub_live ? 1 : 0
  name     = "opshub-prod-dump"
  slug     = "opshub-prod-dump"
  tags     = ["opshub", "prod", "backup"]
  desc     = "Nightly pg_dump -Fc of pg-opshub (CUTOVER-2026-11 D2.6 exit gate; ONPREM-PLAN §10.2). Ping /start, then success or /fail. Ping key: kv-qnsc-prod via ESO."
  channels = var.healthchecks_channel_ids
  schedule = "45 1 * * *"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 7200

  lifecycle {
    precondition {
      condition     = length(var.healthchecks_channel_ids) > 0
      error_message = "healthchecks_channel_ids is empty — the flip PR must set the Teams + devops@ channel UUIDs (§12 routing)."
    }
  }
}

# Weekly restore test, SECOND pass (§10.4: ONE Sun 04:00 job, rova pass then
# opshub pass — batch runs one job at a time; this check pings on the opshub
# pass). Schedule at the job start, 04:00; grace 1 h is sized for BOTH passes
# (2 × ~15 min per §5.7's restore-test size + margin). The job pings /start at
# the beginning of its opshub pass, success or /fail at the end — /start makes
# the 45-min-per-pass over-run alert (§12) the job's own responsibility; this
# check covers "failed or missed". CUTOVER D2.6: green BEFORE any announcement.
resource "healthchecksio_check" "opshub_prod_restore" {
  count    = local.opshub_live ? 1 : 0
  name     = "opshub-prod-restore"
  slug     = "opshub-prod-restore"
  tags     = ["opshub", "prod", "restore-test"]
  desc     = "Sun 04:00 restore test, pg-opshub pass (second sequential pass; ONPREM-PLAN §10.4). Ping /start on pass start, success or /fail at end. Ping key: kv-qnsc-prod via ESO."
  channels = var.healthchecks_channel_ids
  schedule = "0 4 * * 0"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 3600

  lifecycle {
    precondition {
      condition     = length(var.healthchecks_channel_ids) > 0
      error_message = "healthchecks_channel_ids is empty — the flip PR must set the Teams + devops@ channel UUIDs (§12 routing)."
    }
  }
}

# Sunday Azure Blob copy of the pg-opshub dumps (§10.3: weekly, locked 14 d).
# 03:15 = rova's 03:00 Sunday slot + 15 min. Grace 1 d on the weekly schedule
# ≈ §12's "Azure copy > 8 d" alert.
resource "healthchecksio_check" "opshub_prod_azure_copy" {
  count    = local.opshub_live ? 1 : 0
  name     = "opshub-prod-azure-copy"
  slug     = "opshub-prod-azure-copy"
  tags     = ["opshub", "prod", "backup", "azure"]
  desc     = "Sunday copy of pg-opshub dumps to Azure Blob, locked 14 d (ONPREM-PLAN §10.3). Ping success or /fail. Ping key: kv-qnsc-prod via ESO."
  channels = var.healthchecks_channel_ids
  schedule = "15 3 * * 0"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 86400

  lifecycle {
    precondition {
      condition     = length(var.healthchecks_channel_ids) > 0
      error_message = "healthchecks_channel_ids is empty — the flip PR must set the Teams + devops@ channel UUIDs (§12 routing)."
    }
  }
}

# Door-terminal liveness (ADR ATTENDANCE-DEVICE §4, verbatim design): an
# ExclusiveJob in the opshub worker runs EVERY 5 MINUTES and pings the check
# named `door-terminal` ONLY IF every active terminal's last_seen_at is within
# 10 minutes. timeout 300 = the 5-min job cadence; grace 600 = the 10-min
# freshness bound. Healthchecks.io alerts on the missed ping and on recovery.
resource "healthchecksio_check" "door_terminal" {
  count    = local.opshub_live ? 1 : 0
  name     = "door-terminal" # the exact name ADR §4 specifies
  slug     = "door-terminal"
  tags     = ["opshub", "prod", "door"]
  desc     = "opshub worker ExclusiveJob, 5 min; pings only if every active terminal's last_seen_at < 10 min (ADR ATTENDANCE-DEVICE §4). Ping key: kv-qnsc-prod via ESO."
  channels = var.healthchecks_channel_ids
  timeout  = 300
  grace    = 600

  lifecycle {
    precondition {
      condition     = length(var.healthchecks_channel_ids) > 0
      error_message = "healthchecks_channel_ids is empty — the flip PR must set the Teams + devops@ channel UUIDs (§12 routing)."
    }
  }
}
