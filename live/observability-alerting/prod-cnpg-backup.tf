# =============================================================================
# prod CNPG backup age — pg-opshub and pg-kb (P3 launch, 2026-11-04).
#
# WHY NOT A 5xx RULE: SA verified in Grafana Cloud (2026-11-04) that NO
# `http_server_*` series exist for any product, dev or prod — the app HTTP
# metrics are an instrumentation follow-up, not this PR. Availability for
# opshub/kb prod is the readyz Synthetic check (opshub-prod.tf / kb-prod.tf)
# plus the shared Kubernetes rules.
#
# WHY NO FLAG: every rule here is silent until its cluster exists. The metric
# selectors only match a live CNPG scrape, and the "exporter up but no backup
# metric" branch is itself gated on the exporter series. A cluster that does
# not exist yet produces an empty result, and no_data_state = OK is the gate.
#
# ── THE ABSENT-TARGET GATE (and why `== 1`) ────────────────────────────────
# The fallback branch is `(cnpg_collector_up{…} == 1) * 0 + 1e9`: it exists
# only while the exporter reports UP. Without `== 1` an exporter that is down
# (metric present with value 0) would look like "cluster exists, no backup"
# and page for the wrong reason — a down exporter is the Postgres-readiness
# rule's signal, not this one's. So:
#   cluster absent   → no series at all      → no data → OK
#   exporter down    → comparison filters it → no data → OK (readiness pages)
#   exporter up, no backup metric → 1e9 s > 26 h → pages
#
# ── DAY-0 (`immediate: true`) ──────────────────────────────────────────────
# pg-opshub's ScheduledBackup sets `immediate: true`
# (gitops platform/opshub-prod/pg-opshub-backup.yaml:74), so a base backup is
# taken at creation and its metric appears within minutes: the inline
# fallback is safe at `for: 15m`.
# pg-kb has NO manifest in gitops yet. If D creates it without `immediate`, a
# brand-new (empty) cluster has no backup metric until the next 19:xx slot, so
# that fallback lives in its OWN rule with `for: 6h` — long enough for a
# scheduled backup to land, short enough to page the same day. The age rule
# above it keeps 15m against the real metric.
#
# ── NOT HERE ───────────────────────────────────────────────────────────────
# * Replication lag — onprem-k3s.tf's k3s-cnpg-replication-lag has no cluster
#   filter, so pg-opshub/pg-kb are already covered (single instance on day 1:
#   series absent, no_data_state = OK keeps it silent).
# * Postgres not Ready — onprem-workloads.tf's pg-rova rule matches every
#   `pg-<name>-<n>` pod in data-prod, where both clusters live.
# * Dump/restore misses — Healthchecks.io owns the batch-job pings.
# * pg-rova's backup age — onprem-data-p0.tf (that cluster predates this PR).
# =============================================================================

locals {
  prod_cnpg_backup_rules = {
    pg_opshub_backup_age = {
      name = "opshub-pg-backup-too-old"
      # Two metric families can carry the same labels: the in-tree
      # cnpg_collector_* one (exists with value 0 when the barman-cloud path is
      # used) and the plugin one. `or` would keep the first series and drop the
      # plugin's, so zero samples are filtered out BEFORE max (a 0 is "never",
      # not "1970"). Same shape as the pg-rova rule.
      expr = join(" or ", [
        "time() - max by (cnpg_cluster) ({__name__=~\"cnpg_collector_last_available_backup_timestamp|barman_cloud_cloudnative_pg_io_last_available_backup_timestamp\", cluster=\"qnsc-onprem\", cnpg_cluster=\"pg-opshub\"} > 0)",
        # Inline fallback is safe: immediate: true gives the cluster a backup at creation.
        "(max by (cnpg_cluster) (cnpg_collector_up{cluster=\"qnsc-onprem\", cnpg_cluster=\"pg-opshub\"}) == 1) * 0 + 1e9",
      ])
      op        = "gt"
      threshold = 26 * 3600
      for       = "15m"
      no_data   = "OK"
      product   = "opshub"
      severity  = "critical"
      summary   = "No successful pg-opshub base backup for over 26 hours (or the cluster reports and has no backup metric at all). WAL archiving alone cannot restore; check the ScheduledBackup and the R2 token."
    }
    pg_kb_backup_age = {
      name      = "kb-pg-backup-too-old"
      expr      = "time() - max by (cnpg_cluster) ({__name__=~\"cnpg_collector_last_available_backup_timestamp|barman_cloud_cloudnative_pg_io_last_available_backup_timestamp\", cluster=\"qnsc-onprem\", cnpg_cluster=\"pg-kb\"} > 0)"
      op        = "gt"
      threshold = 26 * 3600
      for       = "15m"
      no_data   = "OK"
      product   = "kb"
      severity  = "critical"
      summary   = "No successful pg-kb base backup for over 26 hours. WAL archiving alone cannot restore; check the ScheduledBackup and the R2 token."
    }
    pg_kb_backup_missing = {
      name = "kb-pg-backup-missing"
      # Fallback in its own rule: pg-kb's ScheduledBackup is not in gitops yet,
      # so day 0 cannot assume `immediate: true` (see header). 6 h lets the
      # first scheduled slot (19:xx) land before paging.
      expr = join(" unless on (cnpg_cluster) ", [
        "(max by (cnpg_cluster) (cnpg_collector_up{cluster=\"qnsc-onprem\", cnpg_cluster=\"pg-kb\"}) == 1)",
        "({__name__=~\"cnpg_collector_last_available_backup_timestamp|barman_cloud_cloudnative_pg_io_last_available_backup_timestamp\", cluster=\"qnsc-onprem\", cnpg_cluster=\"pg-kb\"} > 0)",
      ])
      op        = "gt"
      threshold = 0
      for       = "6h"
      no_data   = "OK"
      product   = "kb"
      severity  = "critical"
      summary   = "pg-kb reports UP but no base-backup metric has ever appeared. The Backup/ObjectStore wiring is broken — restores have no source."
    }
  }
}

resource "grafana_rule_group" "prod_cnpg_backup_age" {
  name             = "prod (CNPG — backup age)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.prod_cnpg_backup_rules
    iterator = r
    content {
      name           = r.value.name
      condition      = "B"
      for            = r.value.for
      no_data_state  = r.value.no_data
      exec_err_state = "KeepLast"

      data {
        ref_id         = "A"
        query_type     = "instant"
        datasource_uid = data.grafana_data_source.prometheus.uid

        relative_time_range {
          from = 900
          to   = 0
        }

        model = jsonencode({
          refId         = "A"
          datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
          expr          = r.value.expr
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
                type   = r.value.op
                params = [r.value.threshold]
              }
            }
          ]
          intervalMs    = 1000
          maxDataPoints = 43200
        })
      }

      labels = {
        product  = r.value.product
        env      = "production" # matches the notification policy matcher, NOT "prod"
        severity = r.value.severity
      }

      annotations = {
        summary = r.value.summary
      }
    }
  }
}
