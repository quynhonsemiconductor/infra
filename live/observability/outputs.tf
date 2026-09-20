# Consumed by every product's infra when wiring `var.observability.otlp_endpoint`
# (already-declared plumbing in modules/stack — see rally) and when populating
# the `observability-token` secret the observability-agent module reads.
#
# The token is deliberately NOT assembled into the final "Basic base64(...)"
# header here and is NOT written into any product's secret automatically —
# observability-agent's own README documents populating that secret out of
# band, on purpose, to keep the credential out of a product's Terraform state.
# This stack's job stops at handing over the two raw ingredients.

output "otlp_endpoint" {
  value       = grafana_cloud_stack.qnsc.otlp_url
  description = "var.observability.otlp_endpoint for every product's modules/stack call."
}

output "otlp_stack_id" {
  value       = grafana_cloud_stack.qnsc.id
  description = "Instance id half of the Basic auth pair — see observability-agent's README for the exact `aws secretsmanager put-secret-value` command."
}

output "otlp_push_token" {
  value       = grafana_cloud_access_policy_token.otlp_push.token
  description = "Token half of the Basic auth pair. Sensitive — read via `tofu output -raw` when populating a product's observability-token secret, never logged."
  sensitive   = true
}

# ── The three outputs below are THIS stack's contract with the sibling
# `observability-alerting` stack, which reads them via `terraform_remote_state`
# to configure its single, non-aliased `grafana` provider — the split that
# replaced the old in-stack provider alias (see main.tf header). They are ALSO
# what every product's own infra consumes for the `grafana` provider that
# manages its alert rules — a different credential from otlp_push above (see
# main.tf's "Alerting credential" comment for why). Unlike the OTLP token, this
# one is needed at TOFU PLAN/APPLY time, not just app runtime, so it reaches
# each product as a CI secret (e.g. `GRAFANA_ALERTS_TOKEN`), never through AWS
# Secrets Manager — nothing in a running task ever needs it.

output "alerting_grafana_url" {
  value       = grafana_cloud_stack.qnsc.url
  description = "var.grafana_alerting.url — the Grafana INSTANCE URL. Consumed by observability-alerting's provider and by every product's `grafana` provider block."
}

output "alerting_service_account_token" {
  value       = grafana_cloud_stack_service_account_token.alerting.key
  description = "Sensitive — the stack service account token. observability-alerting authenticates its `grafana` provider with this; products read it via `tofu output -raw` when populating a GRAFANA_ALERTS_TOKEN CI secret. Never write to AWS Secrets Manager: this credential has no reason to ever be reachable from inside a running ECS task."
  sensitive   = true
}

output "alerting_stack_slug" {
  value       = grafana_cloud_stack.qnsc.slug
  description = "The stack slug — observability-alerting builds the auto-provisioned Prometheus datasource name (`grafanacloud-<slug>-prom`) from it, matching alerting_prometheus_datasource_name below."
}

output "alerting_prometheus_datasource_name" {
  value       = "grafanacloud-${grafana_cloud_stack.qnsc.slug}-prom"
  description = <<-EOT
    var.grafana_alerting.prometheus_datasource_name — Grafana Cloud's
    auto-provisioned Prometheus datasource name for this stack. A NAME, not
    a UID: looking up the UID needs a real `data` read against the Grafana
    instance API at PLAN time, which fails here on a fresh apply — the
    service account token that read would authenticate with doesn't exist
    yet in the SAME plan that creates it (data sources can't defer to apply
    the way resources can). `observability-alerts` resolves the UID itself,
    where its own provider config is always a plain, already-known CI
    secret value by the time any product applies — no such bootstrap
    ordering problem there.
  EOT
}
