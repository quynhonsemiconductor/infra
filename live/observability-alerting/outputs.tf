# Folder UIDs every product's infra consumes for the `grafana` resources that
# manage its alert rules and dashboards. These moved here from `observability`
# along with the `grafana_folder` resources they reference (§ observability
# split): the folders live inside the Grafana instance, so they belong in the
# instance-API stack, not the Grafana Cloud ORG stack. The provider credential
# a product needs alongside these is `observability`'s alerting_grafana_url /
# alerting_service_account_token outputs — see that stack for why those reach a
# product as a CI secret, never through AWS Secrets Manager.

output "alerting_folder_uid" {
  value       = grafana_folder.alerts.uid
  description = "var.grafana_alerting.folder_uid — the shared folder every product's rule groups live under."
}

output "dashboards_folder_uid" {
  value       = grafana_folder.dashboards.uid
  description = "The PARENT folder for every product's own dashboards. Each product gets its own SUBFOLDER under this one (Grafana's nested-folder support, `parent_folder_uid`) — unlike alerting_folder_uid, which stays flat: dashboards multiply per product (Overview, Runtime, business KPIs) in a way a rule group per product never does, so a subfolder scales where a title-distinguished flat folder would get crowded."
}

output "rova_dashboards_folder_uid" {
  value       = grafana_folder.rova_dashboards.uid
  description = "rova's dashboard subfolder (renamed from Rally 2026-11-06, same UID) — created ONCE here, not per-environment. See the resource's own comment for the duplicate-folder bug this replaces."
}

# Kept for one release: product CI may still read the old output name. Same
# UID, so a consumer that switches later changes nothing in Grafana.
output "rally_dashboards_folder_uid" {
  value       = grafana_folder.rova_dashboards.uid
  description = "DEPRECATED alias of rova_dashboards_folder_uid (same UID). Remove after the rova product repo switches names."
}

output "slos_folder_uid" {
  value       = grafana_folder.slos.uid
  description = "Shared SLOs folder, under the QNSC parent — pass to grafana_slo's folder_uid so a product's SLOs land here instead of Grafana's default SLO folder."
}
