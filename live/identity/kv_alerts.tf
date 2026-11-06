# ── Key Vault alerting (platform hardening decision 3, "logging + alerts first") ─
#
# The four vaults have written their AuditEvent stream to stqnsckvaudit since
# audit_logs.tf, but nothing ever READ it: a secret enumeration, a denied read
# or a deletion was durable and unwatched (H's 2026-11-06 hardening audit).
#
# ── WHY AZURE-NATIVE, NOT GRAFANA ──────────────────────────────────────────
# The data-plane events exist only as diagnostic logs. The immutability-locked
# storage container is the retention record, not a query surface: neither
# Azure Monitor alert rules nor Grafana Cloud's Azure Monitor datasource can
# run KQL over blobs. Grafana would therefore need the same Log Analytics
# workspace this file adds — plus an Azure Monitor datasource and a credential
# in Grafana Cloud — so it is strictly more moving parts for the same data.
# The cheapest CORRECT path is one small workspace as a second destination on
# the existing diagnostic setting (storage stays the immutable 365-day copy),
# three scheduled-query rules on it, and four Activity Log alerts that cost no
# ingestion at all because the control plane is already collected by Azure.
# Audit volume is a few KB per secret read, so the workspace is cents/month at
# this estate's size; `daily_quota_gb = 1` bounds the worst case.
#
# ── CONTROL PLANE VS DATA PLANE ────────────────────────────────────────────
#   data plane (read/delete/deny)  -> AuditEvent logs -> workspace -> KQL rules
#   control plane (vault delete,   -> Azure Activity  -> activity-log alerts
#   purge, access-policy or RBAC      (always on, no diagnostic setting)
#   change)
#
# ── WHAT "KNOWN PRINCIPAL" MEANS ───────────────────────────────────────────
# Reads that are expected: the three ESO service principals (their workload-
# identity token carries the APPLICATION's client id, and the SP object id is
# what the audit `oid` claim can carry) and the platform-admin users who are
# documented as the only humans holding Secrets Officer. The allowlist is
# derived from resources and one existing variable, never hand-typed:
# adding an ESO store or an admin immediately widens it, and removing one
# narrows it in the same apply. A read by anything else pages.
#
# Scope note: the CI read identity holds Key Vault READER (metadata only) and
# never appears in a secret-value read, so it is deliberately absent.

# ── Notification address ──────────────────────────────────────────────────
# This repository is PUBLIC. The alert recipient is therefore an input, not a
# literal: the owner kit reads IDENTITY_KV_AUDIT_EMAIL from the owner's shell
# and exports TF_VAR_kv_audit_email (scripts/owner/identity-env). No default —
# a plan without it fails instead of silently routing alerts nowhere.
variable "kv_audit_email" {
  type        = string
  description = "Recipient for Key Vault audit alerts. Supplied by the owner kit from IDENTITY_KV_AUDIT_EMAIL; never committed (public repo)."
  sensitive   = false

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.kv_audit_email))
    error_message = "kv_audit_email must be a single email address, e.g. user@example.invalid."
  }
}

locals {
  kv_audit_allowed_app_ids = [for app in azuread_application.eso : app.client_id]
  kv_audit_allowed_object_ids = concat(
    [for sp in azuread_service_principal.eso : sp.object_id],
    tolist(var.platform_admin_object_ids),
  )

  # Built once so the two KQL strings cannot drift from the allowlist.
  kv_audit_allowed_apps_json = jsonencode(local.kv_audit_allowed_app_ids)
  kv_audit_allowed_oids_json = jsonencode(local.kv_audit_allowed_object_ids)
}

# ── The query surface ─────────────────────────────────────────────────────
# Key Vault diagnostic logs use the legacy AzureDiagnostics table (the service
# exposes no resource-specific table for AuditEvent), so every query filters
# Category == "AuditEvent" AND ResourceType == "VAULTS".
resource "azurerm_log_analytics_workspace" "kv_audit" {
  name                = "log-qnsc-kvaudit"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  # A cap, not a target: Key Vault audit volume is KBs/day. If the cap is ever
  # hit, ingestion stops and the immutable storage copy is still complete.
  daily_quota_gb = 1
  # No local keys: the alert rules are the only readers, and they authenticate
  # as the resource through Azure Monitor.
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_monitor_action_group" "kv_audit" {
  name                = "ag-qnsc-kv-audit"
  resource_group_name = azurerm_resource_group.platform.name
  short_name          = "kv-audit"
  tags                = local.tags

  email_receiver {
    name                    = "audit"
    email_address           = var.kv_audit_email
    use_common_alert_schema = true
  }
}

# ── Data plane: three scheduled-query rules (+ the silence check below) ───
# `time_aggregation_method = "Count"` with `threshold = 0` fires on ANY row
# the query returns; the queries already aggregate per identity/client, so a
# single row is one event class, not one log line. (`kv-audit-silent` at the
# end uses Maximum/LessThan instead, because its query returns exactly one
# numeric row.)

# 1. Any secret/key/certificate deletion. Soft delete makes it recoverable,
#    but on a vault that holds deploy credentials it is never routine.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kv_deletion" {
  name                  = "kv-audit-deletion"
  resource_group_name   = azurerm_resource_group.platform.name
  location              = azurerm_resource_group.platform.location
  scopes                = [azurerm_log_analytics_workspace.kv_audit.id]
  description           = "A secret, key or certificate was deleted from a QNSC Key Vault."
  severity              = 1
  enabled               = true
  evaluation_frequency  = "PT5M"
  window_duration       = "PT15M"
  skip_query_validation = false
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where Category == "AuditEvent" and ResourceType == "VAULTS"
      | where OperationName in ("SecretDelete", "KeyDelete", "CertificateDelete")
      | extend objectId = tostring(identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g), appId = tostring(identity_claim_appid_g)
      | summarize deletions = count() by Resource, OperationName, objectId, appId, CallerIPAddress, bin(TimeGenerated, 15m)
    KQL
    time_aggregation_method = "Count"
    metric_measure_column   = "deletions"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.kv_audit.id]
  }
}

# 2. A burst of failed accesses: forbidden/unauthorised responses are the
#    signature of a stale credential or a probe. Five in 15 minutes from one
#    client is not a transient.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kv_denied_spike" {
  name                  = "kv-audit-denied-spike"
  resource_group_name   = azurerm_resource_group.platform.name
  location              = azurerm_resource_group.platform.location
  scopes                = [azurerm_log_analytics_workspace.kv_audit.id]
  description           = "Five or more denied Key Vault data-plane operations in 15 minutes."
  severity              = 2
  enabled               = true
  evaluation_frequency  = "PT5M"
  window_duration       = "PT15M"
  skip_query_validation = false
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where Category == "AuditEvent" and ResourceType == "VAULTS"
      | where httpStatusCode_d in (401, 403)
      // A 401 on the Authentication operation is the SDK's normal first
      // unauthenticated probe, not a denied access (Microsoft's own Key Vault
      // workbook excludes exactly this pair). ResultType is NOT usable here:
      // it reads "Success" even for a Forbidden/403 row — the log entry was
      // written successfully, the operation was not.
      | where not(OperationName == "Authentication" and httpStatusCode_d == 401)
      | extend objectId = tostring(identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g), appId = tostring(identity_claim_appid_g)
      | summarize denied = count() by Resource, objectId, appId, CallerIPAddress, ResultSignature, httpStatusCode_d, bin(TimeGenerated, 15m)
      | where denied >= 5
    KQL
    time_aggregation_method = "Count"
    metric_measure_column   = "denied"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.kv_audit.id]
  }
}

# 3. A read by a principal that is not on the allowlist above. This is the
#    rule the whole file exists for: enumeration is otherwise invisible.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kv_unknown_principal" {
  name                  = "kv-audit-unknown-principal"
  resource_group_name   = azurerm_resource_group.platform.name
  location              = azurerm_resource_group.platform.location
  scopes                = [azurerm_log_analytics_workspace.kv_audit.id]
  description           = "A Key Vault secret/key/certificate was read by a principal outside the ESO + platform-admin allowlist."
  severity              = 2
  enabled               = true
  evaluation_frequency  = "PT15M"
  window_duration       = "PT1H"
  skip_query_validation = false
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      let allowedAppIds = dynamic(${local.kv_audit_allowed_apps_json});
      let allowedObjectIds = dynamic(${local.kv_audit_allowed_oids_json});
      AzureDiagnostics
      | where Category == "AuditEvent" and ResourceType == "VAULTS"
      | where OperationName in ("SecretGet", "SecretList", "SecretListVersions", "KeyGet", "KeyList", "KeyListVersions", "CertificateGet", "CertificateList", "CertificateListVersions")
      | extend objectId = tostring(identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g), appId = tostring(identity_claim_appid_g)
      | where not(set_has_element(allowedAppIds, appId)) and not(set_has_element(allowedObjectIds, objectId))
      | summarize reads = count() by Resource, objectId, appId, CallerIPAddress, bin(TimeGenerated, 15m)
    KQL
    time_aggregation_method = "Count"
    metric_measure_column   = "reads"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.kv_audit.id]
  }
}

# ── Control plane: Activity Log alerts (no ingestion, no workspace query) ──
# These watch the subscription's Administrative event stream, which Azure
# records unconditionally. The four events are the ones that change who may
# read a value or remove the vault itself.

resource "azurerm_monitor_activity_log_alert" "kv_vault_deleted" {
  name                = "kv-activity-vault-deleted"
  resource_group_name = azurerm_resource_group.platform.name
  location            = "global"
  scopes              = ["/subscriptions/${var.subscription_id}"]
  description         = "A QNSC Key Vault was deleted (soft delete; purge-protected vaults stay recoverable, dev does not)."
  enabled             = true
  tags                = local.tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.KeyVault/vaults/delete"
  }

  action {
    action_group_id = azurerm_monitor_action_group.kv_audit.id
  }
}

resource "azurerm_monitor_activity_log_alert" "kv_vault_purged" {
  name                = "kv-activity-vault-purged"
  resource_group_name = azurerm_resource_group.platform.name
  location            = "global"
  scopes              = ["/subscriptions/${var.subscription_id}"]
  description         = "A deleted QNSC Key Vault was PURGED — the last copy of its secrets and keys is gone permanently."
  enabled             = true
  tags                = local.tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.KeyVault/locations/deletedVaults/purge/action"
  }

  action {
    action_group_id = azurerm_monitor_action_group.kv_audit.id
  }
}

resource "azurerm_monitor_activity_log_alert" "kv_access_policy_changed" {
  name                = "kv-activity-access-policy-changed"
  resource_group_name = azurerm_resource_group.platform.name
  location            = "global"
  scopes              = ["/subscriptions/${var.subscription_id}"]
  description         = "A Key Vault access policy was written. The vaults use Azure RBAC, but any change to vault permissions must be visible."
  enabled             = true
  tags                = local.tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.KeyVault/vaults/accessPolicies/write"
  }

  action {
    action_group_id = azurerm_monitor_action_group.kv_audit.id
  }
}

resource "azurerm_monitor_activity_log_alert" "kv_rbac_changed" {
  name                = "kv-activity-rbac-changed"
  resource_group_name = azurerm_resource_group.platform.name
  location            = "global"
  # SUBSCRIPTION scope, not the platform RG: a role assignment on a vault, a
  # managed identity, or anything this stack owns is caught, and moving a
  # future vault to another RG does not quietly take it out of view.
  scopes      = ["/subscriptions/${var.subscription_id}"]
  description = "A role assignment was written in the subscription — includes every Key Vault Secrets Officer/User grant."
  enabled     = true
  tags        = local.tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.Authorization/roleAssignments/write"
  }

  action {
    action_group_id = azurerm_monitor_action_group.kv_audit.id
  }
}

# ── Blind-pipe coverage ────────────────────────────────────────────────────
# Everything above assumes audit events reach the workspace. These three
# alerts watch the pipe itself: a diagnostic setting removed or rewritten, and
# a full day with no AuditEvent at all.

resource "azurerm_monitor_activity_log_alert" "kv_diagnostic_settings_written" {
  name                = "kv-activity-diagnostic-settings-written"
  resource_group_name = azurerm_resource_group.platform.name
  location            = "global"
  scopes              = ["/subscriptions/${var.subscription_id}"]
  description         = "A diagnostic setting was written — someone changed where Key Vault audit events go."
  enabled             = true
  tags                = local.tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.Insights/diagnosticSettings/write"
  }

  action {
    action_group_id = azurerm_monitor_action_group.kv_audit.id
  }
}

resource "azurerm_monitor_activity_log_alert" "kv_diagnostic_settings_deleted" {
  name                = "kv-activity-diagnostic-settings-deleted"
  resource_group_name = azurerm_resource_group.platform.name
  location            = "global"
  scopes              = ["/subscriptions/${var.subscription_id}"]
  description         = "A diagnostic setting was DELETED — Key Vault audit events may no longer be recorded."
  enabled             = true
  tags                = local.tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.Insights/diagnosticSettings/delete"
  }

  action {
    action_group_id = azurerm_monitor_action_group.kv_audit.id
  }
}

# No AuditEvent in the last 24 h. `summarize count()` returns one row (0) on
# empty input, so this rule can fire on silence — a plain "no results" query
# could not. One evaluation per hour is enough: ESO refreshes its stores well
# inside a day, so a day of total silence means the pipe is blind, not quiet.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kv_audit_silent" {
  name                  = "kv-audit-silent"
  resource_group_name   = azurerm_resource_group.platform.name
  location              = azurerm_resource_group.platform.location
  scopes                = [azurerm_log_analytics_workspace.kv_audit.id]
  description           = "No Key Vault AuditEvent has reached the workspace for 24 hours — the audit pipe is blind."
  severity              = 2
  enabled               = true
  evaluation_frequency  = "PT1H"
  window_duration       = "P1D"
  skip_query_validation = false
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where Category == "AuditEvent" and ResourceType == "VAULTS"
      | summarize events = count()
    KQL
    time_aggregation_method = "Maximum"
    metric_measure_column   = "events"
    operator                = "LessThan"
    threshold               = 1
  }

  action {
    action_groups = [azurerm_monitor_action_group.kv_audit.id]
  }
}
