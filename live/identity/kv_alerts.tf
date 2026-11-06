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
    name                    = "devops"
    email_address           = "devops@qnsc.vn"
    use_common_alert_schema = true
  }
}

# ── Data plane: three scheduled-query rules ───────────────────────────────
# `time_aggregation_method = "Count"` with `threshold = 0` fires on ANY row
# the query returns; the queries already aggregate per identity/client, so a
# single row is one event class, not one log line.

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
      | where ResultType != "Success"
      | extend objectId = tostring(identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g), appId = tostring(identity_claim_appid_g)
      | summarize denied = count() by Resource, objectId, appId, CallerIPAddress, ResultType, bin(TimeGenerated, 15m)
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
      | where OperationName in ("SecretGet", "KeyGet", "CertificateGet")
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
  # The platform RG: every Key Vault and every role assignment this stack
  # creates lives under it, so a vault-scoped RBAC write appears here.
  scopes      = [azurerm_resource_group.platform.id]
  description = "A role assignment was written in rg-qnsc-platform — the scope that carries Key Vault Secrets Officer/User."
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
