# =============================================================================
# opshub prod monitoring (H-D23) — CUTOVER-2026-11 Stage D2 prerequisite.
#
# DISABLED UNTIL CUTOVER. Every resource here is `count = var.opshub_prod_live ? 1 : 0`
# with the variable defaulting to `false`, so today's plan is a no-op and the
# nightly drift job sees nothing. In the D2 window the owner:
#   1. adds the repo secrets `GRAFANA_SM_TOKEN` (Synthetic Monitoring API token,
#      stack → Synthetic Monitoring → Your API token) and `HEALTHCHECKS_API_TOKEN`,
#   2. flips the repo variable `OPSHUB_PROD_LIVE` to `true` (D2.4 wires the
#      `opshub.qnsc.vn` DNS + routes; the check is only useful after that apply),
# and the next plan shows exactly four creates + one Synthetic check create.
#
# WHY THESE LIVE IN TERRAFORM NOW, NOT AT CUTOVER: Stage D2's prerequisites are
# "drafted before the window, SA-reviewed" (CUTOVER-2026-11, D2 prereq list:
# "live/observability: Synthetic opshub.qnsc.vn/readyz; Healthchecks
# opshub-prod-dump, the pg-opshub restore pass, and the Sunday Azure copy" —
# the door-terminal check joins them per ADR ATTENDANCE-DEVICE §2.4). Reviewing
# a disabled definition costs nothing; drafting it mid-window does.
#
# SCHEDULES MIRROR THE ROVA PROD DEFINITIONS (plan §10.2/§10.3/§12), with
# opshub's documented +15-minute stagger: dump 01:45 (rova 01:30), restore test
# Sun 04:15 (rova 04:00), Azure copy Sunday. Alert thresholds are the plan's:
# dump > 26 h, restore test running > 45 min, Azure copy > 8 d.
#
# NOTE FOR THE REVIEWER: this stack is the right HOME (org-level Grafana +
# external check APIs), but it is not plannable today for a pre-existing
# reason — its state still holds the grafana_* objects the 2026-09-20 split
# moved to observability-alerting (orphaned provider alias; see the stack
# list comments in infra-plan.yml and docs/runbooks/observability-state-migration.md).
# The plan failures on this PR are that issue, not these resources.
# =============================================================================

variable "opshub_prod_live" {
  description = "Flip to true in the Stage D2 window (CUTOVER-2026-11) — a one-word PR so the flip is SA-reviewed. false = every resource below is culled and the plan shows nothing."
  type        = bool
  default     = false
}

variable "grafana_sm_url" {
  description = "Grafana Synthetic Monitoring API root (global, not the stack URL)."
  type        = string
  default     = "https://synthetic-monitoring-api.grafana.net"
}

variable "grafana_sm_token" {
  description = "Synthetic Monitoring API token — repo secret GRAFANA_SM_TOKEN, wired in infra-plan/infra-apply (empty until the owner adds it). Distinct from GRAFANA_CLOUD_API_KEY."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sm_probe_id" {
  description = "Synthetic Monitoring probe id for the single allowed probe (plan §12: cap 1 probe). Look it up at cutover: GET <sm_url>/api/v1/probes with the SM token — pick Frankfurt, then set it here in the flip PR."
  type        = number
  default     = 1
}

variable "healthchecks_api_token" {
  description = "Healthchecks.io API token (team account) — repo secret HEALTHCHECKS_API_TOKEN, wired in infra-plan/infra-apply (empty until the owner adds it)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "healthchecks_channel_ids" {
  description = "Healthchecks.io channel UUIDs that receive the alerts (the Teams + devops@ integrations configured once in the Healthchecks UI)."
  type        = list(string)
  default     = []
}

# ── Synthetic Monitoring ────────────────────────────────────────────────────
# A SECOND, aliased grafana provider: SM resources authenticate with the SM API
# token (sm_url/sm_token), NOT the org-level GRAFANA_CLOUD_API_KEY the default
# provider uses. With opshub_prod_live = false the alias has zero resource
# instances, so the client never configures and the empty token is never sent —
# the same "no instances, no configuration" rule the observability split
# exploited in reverse (see the header of main.tf).
provider "grafana" {
  alias           = "sm"
  sm_url          = var.grafana_sm_url
  sm_access_token = var.grafana_sm_token
}

# One of the six budgeted checks (plan §12: rova+opshub prod+dev, kb-dev, one
# spare; this IS the opshub-prod slot — the budget does not grow). 5-minute
# HTTP GET, matching rova's check. /readyz is status-only and bypasses nothing
# on prod (no Access on opshub prod, H-D23).
resource "grafana_synthetic_monitoring_check" "opshub_prod_readyz" {
  count     = var.opshub_prod_live ? 1 : 0
  provider  = grafana.sm
  job       = "opshub-prod-readyz"
  target    = "https://opshub.qnsc.vn/readyz"
  frequency = 300000 # ms — every 5 min, same as rova
  timeout   = 5000   # ms — Tunnel hop; validate against the SM API's cap at cutover
  enabled   = true
  probes    = [var.sm_probe_id]
  labels = {
    product = "opshub"
    env     = "prod"
  }
  settings {
    http {
      method = "GET"
    }
  }
}

# ── Healthchecks.io — the batch job pings (plan §12 external row) ───────────
provider "healthchecksio" {
  # Empty key with every check culled = the client never configures; the same
  # rule as the SM alias above.
  api_key = var.healthchecks_api_token
}

# Nightly pg_dump of pg-opshub → R2 dumps/pg-opshub/daily/ (plan §10.2:
# 01:45, the rova 01:30 slot + 15 min). Grace 2 h ≈ the plan's
# "Dump > 26 h" alert (24 h schedule + 2 h grace).
resource "healthchecksio_check" "opshub_prod_dump" {
  count    = var.opshub_prod_live ? 1 : 0
  name     = "opshub-prod-dump"
  tags     = ["opshub", "prod", "backup"]
  channels = var.healthchecks_channel_ids
  schedule = "45 1 * * *"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 7200
}

# Weekly restore test's pg-opshub pass (plan §10.4: Sunday 04:00, batch runs
# one job at a time; opshub staggers +15 min → 04:15). Grace 45 min — the plan's
# "running > 45 min" alert; a failure or a missed run alerts via the same check.
resource "healthchecksio_check" "opshub_prod_restore_test" {
  count    = var.opshub_prod_live ? 1 : 0
  name     = "opshub-prod-restore-test"
  tags     = ["opshub", "prod", "restore-test"]
  channels = var.healthchecks_channel_ids
  schedule = "15 4 * * 0"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 2700
}

# Sunday Azure Blob copy of the pg-opshub dumps (plan §10.3: weekly, locked
# 14 d). Grace 1 d on a weekly schedule ≈ the plan's "Azure copy > 8 d" alert.
resource "healthchecksio_check" "opshub_prod_azure_copy" {
  count    = var.opshub_prod_live ? 1 : 0
  name     = "opshub-prod-azure-copy"
  tags     = ["opshub", "prod", "backup", "azure"]
  channels = var.healthchecks_channel_ids
  schedule = "15 5 * * 0"
  timezone = "Asia/Ho_Chi_Minh"
  grace    = 86400
}

# Door-terminal liveness (ADR ATTENDANCE-DEVICE §2.4/§5): the opshub worker
# pings this check on each successful sweep that finds every enrolled
# terminal's last_seen_at fresh (the terminal itself syncs every 60 s).
# Timeout-based, not cron: 1 h expected interval, 30 min grace. This is the
# check D2.5 falls back to when the real door PRs have not shipped — the
# check is defined here, the worker-side ping lands with the door PRs.
resource "healthchecksio_check" "opshub_door_terminal" {
  count    = var.opshub_prod_live ? 1 : 0
  name     = "opshub-prod-door-terminal"
  tags     = ["opshub", "prod", "door"]
  channels = var.healthchecks_channel_ids
  timeout  = 3600
  grace    = 1800
}
