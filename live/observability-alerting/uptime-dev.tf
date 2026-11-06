# =============================================================================
# Uptime (Synthetic Monitoring) — flag + probes data source; prod checks only (owner 2026-11-05).
#
# rova prod leaves AWS in 1–2 days and team traffic moves to the on-prem
# cluster earlier than the full §12 collector. Until the k8s collector ships
# there are NO Kubernetes metrics to alert on — but uptime can be watched from
# Grafana Synthetic Monitoring today, because the `/readyz` endpoints are real
# and public.
#
# This file OWNS the flag that arms every Synthetic Monitoring check and the
# probes data source they share. The checks themselves are PROD only:
#
#   rova.qnsc.vn/readyz    rova-prod.tf    (90 s, Singapore + Frankfurt)
#   opshub.qnsc.vn/readyz  opshub-prod.tf  (5 min)
#   kb.qnsc.vn/readyz      kb-prod.tf      (5 min)
#
# ── WHY NO DEV CHECKS (removed 2026-11-05) ──────────────────────────────────
# External synthetic checks answer "can a real user reach it"; that is worth
# its budget for prod only. The SM free tier is 100 000 executions / month
# (30 d x 86 400 s / frequency_s x probes): rova prod 57 600 + opshub prod
# 8 640 + kb prod 8 640 = 74 880, leaving ~25 000 for a second probe on opshub /
# kb prod. The three dev checks (25 920) pushed the total to 92 160 and SM
# refused the kb prod check ("check executions quota exceeded"). Dev health is
# covered inside the cluster (onprem-workloads.tf: CrashLoop / Postgres readiness,
# prod-http-5xx.tf per env) — no external probe needed for an internal estate.
#
# ── WHY THE PROBE ID COMES FROM A DATA SOURCE ───────────────────────────────
# The Stage-D flip procedure assumed a human reads the probe id out of the SM
# UI and hard-codes it. The fast track does not have a human in the loop: the
# probes data source reads the SM API with the same token the resources use and
# pins the name "Singapore" in git. One probe per check (§12); rova prod
# also runs from Frankfurt since 2026-11-03 (rova-prod.tf).
#
# ── GATE ────────────────────────────────────────────────────────────────────
# `uptime_checks_enabled` defaults true: the PR is the review, and the merge is
# the arming. The plan still shows nothing when GRAFANA_SM_TOKEN is empty (the
# aliased provider cannot configure, and every instance is culled) — so a
# missing secret degrades to "no checks", never to a failed apply.
# =============================================================================

variable "uptime_checks_enabled" {
  description = "Arms the prod uptime checks (rova, opshub, kb readyz) and their rules. Also honoured by rova-prod.tf's readyz resources. Requires GRAFANA_SM_TOKEN; with an empty token everything is culled."
  type        = bool
  default     = true
}

# The aliased SM provider (monitoring-providers.tf) authenticates the data
# source; count keeps it out of the graph when the flag or the token is absent.
data "grafana_synthetic_monitoring_probes" "main" {
  count    = var.uptime_checks_enabled && var.grafana_sm_token != "" ? 1 : 0
  provider = grafana.sm
}
