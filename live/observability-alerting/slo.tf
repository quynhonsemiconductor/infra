# =============================================================================
# Prod availability SLOs — built on the SYNTHETIC probes, not app telemetry
# (observability audit 2026-11-06 §3). The only older SLO is the AWS-era
# `HTTP availability (production)`, which queries a label value that never
# existed on-prem and is dead. These replace it: the checks exist for every
# prod product, run from outside the cluster, and are independent of the app's
# own OTLP pipeline.
#
# 99.5% over 30 days. `probe_all_success_sum` / `_count` are the per-check
# aggregates Synthetic Monitoring writes; the ratio is the fraction of
# successful executions.
#
# ── SCOPE, deliberately different per product (review 2026-11-06) ──────────
# rova   fast burn (critical -> Teams) + slow burn (warning -> email).
#        Probe runs every 90 s from TWO probes, so a fast burn has real
#        volume: one failed execution is a small share of the window.
# opshub slow burn ONLY (warning -> email). The probe runs every 5 min from
#        ONE probe: a single blip is 1/12 of an hour (8.3%), which would trip
#        a fast-burn critical on one dropped request. Warning is the honest
#        severity for that granularity.
# kb     NO SLO YET. It has ~1 day of prod data (7d baseline 99.24%, below the
#        99.5% objective), so an SLO now would be an SLO already breached and
#        the burn maths would be dominated by launch noise. Add it after 30
#        days of prod history, using the same shape as opshub.
#
# COST: ~15 recording series per SLO; two SLOs, ~30 series.
# =============================================================================

locals {
  prod_availability_slos = {
    rova = {
      name        = "rova prod availability"
      job         = "rova-prod-readyz"
      fast_burn   = true
      why_no_fast = ""
    }
    opshub = {
      name        = "opshub prod availability"
      job         = "opshub-prod-readyz"
      fast_burn   = false
      why_no_fast = "5-minute single-probe check: one blip is 8.3% of the hour, so only the slow burn (email) is armed."
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
    value = "prod"
  }

  alerting {
    dynamic "fastburn" {
      for_each = each.value.fast_burn ? [1] : []
      content {
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
          value = "prod"
        }
      }
    }

    slowburn {
      annotation {
        key   = "name"
        value = "${each.key} prod availability — slow burn"
      }
      annotation {
        key   = "description"
        value = "Error budget for ${each.value.name} is burning faster than the 30-day objective allows.${each.value.why_no_fast == "" ? "" : " Fast burn is not armed: ${each.value.why_no_fast}"}"
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
        value = "prod"
      }
    }
  }
}
