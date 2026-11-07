# =============================================================================
# Databases — ONE templated dashboard over the CNPG clusters (dashboards-gaps
# item 3, owner 2026-11-07). `var cluster` = the `cnpg_cluster` label
# (pg-rova / pg-opshub / pg-kb / pg-dev); no per-cluster copies, and one
# more cluster needs no edit here.
#
# ── ONLY SERIES ALREADY SCRAPED (job integrations/cnpg) ────────────────────
# Every metric below is already used by a rule or dashboard in this stack,
# so it is proven to survive the collector allowlist and Adaptive Metrics:
#
#   cnpg_collector_up{namespace, cnpg_cluster, pod}
#       exporter liveness (platform health + cnpg_exporter_down rule)
#   cnpg_pg_database_size_bytes{namespace, cnpg_cluster, datname}
#       per-database size (k3s-cnpg-database-over-15g rule)
#   cnpg_backends_total{namespace, cnpg_cluster, pod} and
#   cnpg_pg_settings_setting{namespace, cnpg_cluster, name}
#       connections and max_connections (pg-connections alerts)
#   cnpg_collector_last_available_backup_timestamp{cnpg_cluster} OR
#   barman_cloud_cloudnative_pg_io_last_available_backup_timestamp
#       the newest base backup, two spellings (collector vs plugin — the
#       cnpg-backup-age rules `or` them; the panels do the same)
#   cnpg_collector_last_failed_backup_timestamp / barman …_last_failed_…
#       the newest FAILED backup (cnpg_backup_failed rule)
#   cnpg_pg_stat_archiver_failed_count
#       WAL archive failures (k3s-pg-wal-archive-failing rule)
#   cnpg_pg_replication_lag{cnpg_cluster}
#       replica lag in bytes (k3s-pg-replication-lag rule)
#
# ASKED FOR AND NOT HERE (item 3: list it with its cost, do not add series —
# the org billable meter sits at ~8k of the 10k free tier): cache hit ratio,
# transactions/s, deadlocks and longest transaction all read pg_stat_database /
# pg_stat_activity, and CNPG's default monitoring queries (backends,
# pg_settings, replication, wal, pg_stat_archiver) do not collect those
# families at all — they are not dropped by Adaptive Metrics, they are never
# scraped. Turning them on means editing the CNPG `Monitoring` spec per
# cluster and costs roughly: cnpg_pg_stat_database_* 4–6 series per
# cluster×database (~15 for the three prod DBs), a longest-transaction gauge
# ~1 per instance pod (~4), archived_count ~1 per cluster (~4) — call it
# ~20–25 new series. That is a deliberate owner decision, not this PR's.
#
# ── NO __name__ REGEX ──────────────────────────────────────────────────────
# The owner's rule for this pass. The backup-age panels need the two-spelling
# fallback anyway, so they use an exact-name `or` per branch — querying a
# name that is not there returns an empty vector, which `or` skips — instead
# of the `{__name__=~"..."}` glob the alert rules and Platform health use.
# =============================================================================

resource "grafana_dashboard" "databases" {
  folder    = grafana_folder.dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "Databases"
    uid           = "databases"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-24h", to = "now" }
    refresh       = "1m"
    tags          = ["databases", "cnpg", "provisioned"]

    templating = {
      list = [
        {
          name       = "cluster"
          type       = "custom"
          label      = "CNPG cluster"
          query      = "pg-rova,pg-opshub,pg-kb,pg-dev"
          includeAll = true
          multi      = true
          allValue   = ".+"
          current    = { selected = true, text = ["All"], value = ["$__all"] }
        },
      ]
    }

    # Product switcher (item 4): keeps the time range, sets var-cluster.
    links = [
      for c in ["pg-rova", "pg-opshub", "pg-kb"] : {
        title       = c
        type        = "link"
        icon        = "bolt"
        targetBlank = false
        keepTime    = true
        url         = "/d/databases?orgId=1&var-cluster=${c}"
      }
    ]

    panels = [
      {
        id      = 1
        type    = "row"
        title   = "Capacity"
        gridPos = { h = 1, w = 24, x = 0, y = 0 }
      },
      {
        id          = 2
        title       = "Exporters up (worst cluster)"
        description = "min of cnpg_collector_up across the selected clusters. 0 = the CNPG exporter on a pod stopped reporting: backup-age and replication series go silent while it is down."
        type        = "stat"
        gridPos     = { h = 4, w = 6, x = 0, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "none", thresholds = { mode = "absolute", steps = [{ color = "red", value = null }, { color = "green", value = 1 }] } } }
        targets     = [{ expr = "min(cnpg_collector_up{cnpg_cluster=~\"$cluster\"})", refId = "A" }]
      },
      {
        id          = 3
        title       = "Database size, by database"
        description = "cnpg_pg_database_size_bytes per datname — this is how we SEE retention work: a retention change bends this line."
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 6, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "bytes", min = 0, noValue = "no series — the cluster has no size series (pg-kb before its first scrape)" } }
        targets = [{
          expr         = "max by (cnpg_cluster, datname) (cnpg_pg_database_size_bytes{cnpg_cluster=~\"$cluster\"})"
          legendFormat = "{{cnpg_cluster}} {{datname}}"
          refId        = "A"
        }]
      },
      {
        id          = 4
        title       = "DB growth per day"
        description = "Same gauge, slope over the last 6 h annualised to a day (deriv × 86400). Positive and steady = something keeps writing; near zero = retention is holding."
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 18, y = 1 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "Bps", noValue = "needs ≥ 2 points in the window" } }
        targets = [{
          expr         = "max by (cnpg_cluster, datname) (deriv(cnpg_pg_database_size_bytes{cnpg_cluster=~\"$cluster\"}[6h])) * 86400"
          legendFormat = "{{cnpg_cluster}} {{datname}}"
          refId        = "A"
        }]
      },
      {
        id      = 5
        type    = "row"
        title   = "Connections"
        gridPos = { h = 1, w = 24, x = 0, y = 9 }
      },
      {
        id          = 6
        title       = "Connections vs max_connections, per pod"
        description = "The pg-connections alert's own shape, per instance pod: client backends (idle included — an idle session holds a slot) over the server's max_connections setting."
        type        = "timeseries"
        gridPos     = { h = 8, w = 24, x = 0, y = 10 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit", min = 0, max = 1, noValue = "no series — exporter down or allowlisted out (see the pg-connections rule)" } }
        targets = [{
          expr         = "sum by (cnpg_cluster, pod) (cnpg_backends_total{cnpg_cluster=~\"$cluster\"}) / on (cnpg_cluster, pod) max by (cnpg_cluster, pod) (cnpg_pg_settings_setting{cnpg_cluster=~\"$cluster\", name=\"max_connections\"})"
          legendFormat = "{{cnpg_cluster}} {{pod}}"
          refId        = "A"
        }]
      },
      {
        id      = 7
        type    = "row"
        title   = "Backups and WAL"
        gridPos = { h = 1, w = 24, x = 0, y = 18 }
      },
      {
        id          = 8
        title       = "Oldest base backup (hours)"
        description = "Age of the newest good base backup per cluster, from the collector or plugin spelling (whichever reports; exact-name `or`, no __name__ glob). Same number the cnpg-backup-age alerts threshold on: 12 h yellow, 26 h red."
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 0, y = 19 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "h", min = 0, noValue = "no backup timestamp series — exporter down, or no backup has EVER succeeded on that cluster" } }
        targets = [{
          expr = join(" or ", [
            "max by (cnpg_cluster) ((time() - cnpg_collector_last_available_backup_timestamp{cnpg_cluster=~\"$cluster\"}) > 0)",
            "max by (cnpg_cluster) ((time() - barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{cnpg_cluster=~\"$cluster\"}) > 0)",
          ])
          legendFormat = "{{cnpg_cluster}}"
          refId        = "A"
        }]
      },
      {
        id          = 9
        title       = "Hours since last FAILED backup"
        description = "Age of the newest FAILED backup attempt per cluster. Small = a failure just happened (the cnpg-backup-failed alert fires only if no later good backup succeeded); empty = no failure ever recorded."
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 12, y = 19 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "h", min = 0, noValue = "no failure recorded (or the exporter is down)" } }
        targets = [{
          expr = join(" or ", [
            "max by (cnpg_cluster) ((time() - cnpg_collector_last_failed_backup_timestamp{cnpg_cluster=~\"$cluster\"}) > 0)",
            "max by (cnpg_cluster) ((time() - barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp{cnpg_cluster=~\"$cluster\"}) > 0)",
          ])
          legendFormat = "{{cnpg_cluster}}"
          refId        = "A"
        }]
      },
      {
        id          = 10
        title       = "WAL archive failures (10m)"
        description = "increase of cnpg_pg_stat_archiver_failed_count — WAL that Postgres could not hand to the archive. Any sustained rise breaks PITR before the next base backup; the k3s-pg-wal-archive-failing rule pages on the same series. (archived_count, the success side of the same query, is not confirmed kept by Adaptive Metrics — listed in the PR body, not added here.)"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 0, y = 27 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { min = 0, noValue = "no series — archiver query not reporting" } }
        targets = [{
          expr         = "sum by (cnpg_cluster) (increase(cnpg_pg_stat_archiver_failed_count{cnpg_cluster=~\"$cluster\"}[10m]))"
          legendFormat = "{{cnpg_cluster}}"
          refId        = "A"
        }]
      },
      {
        id          = 11
        title       = "Replication lag (bytes)"
        description = "cnpg_pg_replication_lag per cluster — how far a standby trails the primary in WAL bytes. 0 / flat-at-zero = streaming healthy."
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 12, y = 27 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "bytes", min = 0, noValue = "no series — no standby configured on the selected clusters, or exporter down" } }
        targets = [{
          expr         = "max by (cnpg_cluster) (cnpg_pg_replication_lag{cnpg_cluster=~\"$cluster\"})"
          legendFormat = "{{cnpg_cluster}}"
          refId        = "A"
        }]
      },
    ]
  })
}
