# =============================================================================
# Loki -> Tempo correlation, as code (coverage audit 2026-11-07 §6; round 2).
#
# The Grafana Cloud Loki datasource is created by the stack, not by Terraform,
# so this stack never owned it. The provider has a resource for exactly that
# split: `grafana_data_source_config` manages a datasource's JSON configuration
# by `uid` WITHOUT taking ownership of the datasource object itself (deleting
# this resource clears the config; it cannot delete the datasource, and a
# `terraform destroy` of the stack cannot take the logs pipeline with it).
#
# WHAT: one derived field on the Loki datasource. A log line that carries
# `"trace_id":"<32 hex>"` (rova/opshub emit it from the pino mixin; kb does not
# yet — team note in the audit) becomes a click that opens the trace in Tempo.
#
# WHY THE CURRENT JSON IS MERGED BACK, NOT REPLACED: this resource sets the
# ENTIRE jsonData, so it starts from whatever the datasource already has
# (`data.grafana_data_source.logs.json_data_encoded`) and changes only
# `derivedFields`. Any Cloud-managed field (alertmanagerUid, maxLines, ...)
# is carried through unchanged. A derived field already named `trace_id` is
# replaced, never duplicated.
#
# WHY NOT `grafana_data_source` + import: importing the Cloud-provisioned
# datasource into state makes Terraform its owner, and the provider would then
# plan over every field Grafana Cloud sets (uid/url/version/secureJsonData) —
# a drift surface for a resource this repo does not create. The config-only
# resource gives the same result with none of that.
#
# IF THE PLAN FAILS TO READ THE DATASOURCE: the `-traces` name is derived from
# the stack slug the same way `main.tf` derives `-logs`; a rename in Grafana
# Cloud shows up as a plan error, not a silently dead link.
# =============================================================================

data "grafana_data_source" "tempo_for_logs" {
  name = "grafanacloud-${data.terraform_remote_state.observability.outputs.alerting_stack_slug}-traces"
}

locals {
  logs_json = jsondecode(data.grafana_data_source.logs.json_data_encoded)

  # `derivedFields` is null/absent on a datasource that has none.
  logs_existing_derived = try(
    local.logs_json["derivedFields"] == null ? [] : local.logs_json["derivedFields"],
    [],
  )

  # The `$${` is Terraform's escape for a literal `${`: Grafana interpolates it.
  logs_trace_derived_field = {
    datasourceUid   = data.grafana_data_source.tempo_for_logs.uid
    matcherRegex    = "\"trace_id\":\"([a-fA-F0-9]{32})\""
    name            = "trace_id"
    url             = "$${__value.raw}"
    urlDisplayLabel = "View trace in Tempo"
  }

  logs_json_with_trace = merge(local.logs_json, {
    derivedFields = concat(
      [for f in local.logs_existing_derived : f if try(f.name, "") != "trace_id"],
      [local.logs_trace_derived_field],
    )
  })
}

resource "grafana_data_source_config" "logs" {
  uid               = data.grafana_data_source.logs.uid
  json_data_encoded = jsonencode(local.logs_json_with_trace)
}
