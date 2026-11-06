# =============================================================================
# Prod availability SLOs — three products, one shape (observability audit
# 2026-11-06 §3). The only SLO today is the AWS-era `HTTP availability
# (production)`, which queries a label value that never existed on-prem and is
# therefore dead. These replace it, built on the SYNTHETIC probes rather than
# app telemetry: the checks exist for every prod product, run from outside the
# cluster, and are independent of the app's own OTLP pipeline — a dead
# collector cannot also hide the SLO.
#
# 99.5% over 30 days per product. `probe_all_success_sum` / `_count` are the
# per-check aggregates Grafana's Synthetic Monitoring writes; the ratio is the
# fraction of successful probe executions. 7-day baselines measured 2026-11-06:
# rova 99.53%, opshub 99.62%, kb 99.24% (kb only since 11-05).
#
# COST: ~15 recording series per SLO, ~45 in total — inside the ~1.9k billable
# headroom the audit measured.
#
# BURN ALERTS: the fast burn is `severity = critical` (Teams + email after the
# severity split); the slow burn is a warning (email only). Both carry
# product/env so the notification policy groups and routes them like every
# other rule. Thresholds are the SLO app's defaults — deliberately not
# hand-tuned per product at this size.
# =============================================================================

locals {
  prod_availability_slos = {
    rova = {
      name = "rova prod availability"
      job  = "rova-prod-readyz"
    }
    opshub = {
      name = "opshub prod availability"
      job  = "opshub-prod-readyz"
    }
    kb = {
      name = "kb prod availability"
      job  = "kb-prod-readyz"
    }
  }
}

resource "grafana_slo" "prod_availability" {
  for_each = local.prod_availability_slos

  name        = each.value.name
  description = "Share of synthetic probe executions against ${each.value.job} that succeeded, over 30 days (99.5% objective)."
  folder_uid  = grafana_folder.slos.uid

  query {
    type = "ratio"
    ratio {
      success_metric        = "probe_all_success_sum{job=\"${each.value.job}\"}"
      total_metric          = "probe_all_success_count{job=\"${each.value.job}\"}"
      source_datasource_uid = data.grafana_data_source.prometheus.uid
    }
  }

  objectives {
    value  = 0.995
    window = "30d"
  }

  destination_datasource {
    uid = data.grafana_data_source.prometheus.uid
  }

  label {
    key   = "product"
    value = each.key
  }
  label {
    key   = "env"
    value = "production"
  }

  alerting {
    fastburn {
      annotation {
        key   = "name"
        value = "${each.key} prod availability — fast burn"
      }
      annotation {
        key   = "description"
        value = "Error budget for ${each.value.name} is burning too fast; check the synthetic probe results and the prod service."
      }
      label {
        key   = "severity"
        value = "critical"
      }
      label {
        key   = "product"
        value = each.key
      }
      label {
        key   = "env"
        value = "production"
      }
    }

    slowburn {
      annotation {
        key   = "name"
        value = "${each.key} prod availability — slow burn"
      }
      annotation {
        key   = "description"
        value = "Error budget for ${each.value.name} is burning faster than the 30-day objective allows."
      }
      label {
        key   = "severity"
        value = "warning"
      }
      label {
        key   = "product"
        value = each.key
      }
      label {
        key   = "env"
        value = "production"
      }
    }
  }
}
