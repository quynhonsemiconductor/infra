# =============================================================================
# Shared providers and variables for the product-prod monitoring definitions
# (opshub-prod.tf, and rova-prod.tf from its own PR) — CUTOVER-2026-11.
#
# WHY A SECOND, ALIASED grafana PROVIDER: SM resources authenticate with the
# Synthetic Monitoring API token (sm_url/sm_access_token), NOT the org-level
# GRAFANA_CLOUD_API_KEY the default provider uses. While every gated file
# still has zero live resource instances (flags default false), the alias has
# no instances, so the client never configures and the empty tokens are never
# sent — the same "no instances, no configuration" rule the observability
# split exploited in reverse (see the header of main.tf).
#
# WHY THE TOKEN MAPPINGS ARE SCOPED: infra-plan.yml passes them only to this
# stack's matrix entry; infra-apply.yml only to apply-observability-alerting.
#
# HOW THE JOBS PING: by PROJECT PING KEY + SLUG, hc-ping.com/<ping-key>/<slug>.
# The ping key lives ONLY in kv-qnsc-prod and reaches jobs via ESO (§7.1).
# healthchecksio v2.3.0's id/ping_url are NOT sensitive and land in public
# Actions logs — slug-based pings keep them publishable: nothing in tofu
# output needs to be secret. Gated files pin their slugs accordingly.
# =============================================================================

provider "grafana" {
  alias           = "sm"
  sm_url          = var.grafana_sm_url
  sm_access_token = var.grafana_sm_token
}

provider "healthchecksio" {
  api_key = var.healthchecks_api_token
}

variable "grafana_sm_url" {
  description = "Grafana Synthetic Monitoring API root (global, not the stack URL)."
  type        = string
  default     = "https://synthetic-monitoring-api.grafana.net"
}

variable "grafana_sm_token" {
  description = "Synthetic Monitoring API token — repo secret GRAFANA_SM_TOKEN, mapped in infra-plan.yml (matrix-scoped to this stack) and infra-apply.yml (apply-observability-alerting only). Empty until the owner adds it; harmless while every gated file is culled."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sm_probe_id" {
  description = "Synthetic Monitoring probe id for the single allowed probe (§12: cap 1 probe, ≤ 10 checks). Default null — the id is only knowable with a live SM token; each product's flip PR sets it."
  type        = number
  default     = null
}

variable "healthchecks_api_token" {
  description = "Healthchecks.io API token (team account) — repo secret HEALTHCHECKS_API_TOKEN, same mappings as the SM token."
  type        = string
  default     = ""
  sensitive   = true
}

variable "healthchecks_channel_ids" {
  description = "Healthchecks.io channel UUIDs that receive the alerts (the Teams + devops@ integrations, §12). Set by each product's flip PR; the gated checks' preconditions enforce it."
  type        = list(string)
  default     = []
}
