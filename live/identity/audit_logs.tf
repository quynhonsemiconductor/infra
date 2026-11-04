# ── Key Vault data-plane audit trail (platform audit N-M2) ──────────────────
#
# The four vaults had no diagnostic setting, so a secret read or a key operation
# left no record anywhere: Key Vault retains nothing by itself, and the control
# plane (who changed what) is Azure Activity, not the data plane (who READ
# which secret). This file writes the data-plane AuditEvent stream to a small
# storage account with a one-year retention, which is the cheapest destination
# available (no Log Analytics workspace: ~cents/month at this volume).
#
# Scope, deliberately: the three purge-protected vaults and kv-qnsc-dev. Every
# secret VALUE stays out of this stream — Key Vault never logs secret contents,
# only the caller, the operation and the object name.
#
# Retention: the lifecycle rule below deletes the diagnostic container's blobs
# after 365 days. Azure writes one path per hour under
# insights-logs-auditevent, so the prefix filter is exact.
#
# This is the owner decision "logging + alerts first; firewall later" (PLAN-
# PLATFORM-HARDENING 2026-11-04, decision 3): the vault firewall stays as it is
# (public network allowed, office_ip unset) until the audit trail exists.

locals {
  # Keyed like the vaults themselves so the diagnostic-setting addresses read
  # kv-audit["prod"], kv-audit["dev"], … in a plan.
  audit_vaults = merge(
    { for key, vault in azurerm_key_vault.purge_protected : key => vault.id },
    { dev = azurerm_key_vault.dev.id },
  )
}

resource "azurerm_storage_account" "kv_audit" {
  # Skips, one posture: this account holds audit LOGS, is reached only by the
  # Azure Monitor service and the owner's read-only queries, and the on-prem
  # cluster has no VNet to privatize into (same reason as the state account).
  # checkov:skip=CKV_AZURE_33:no queue/table service is used — the account holds only diagnostic blobs
  # checkov:skip=CKV_AZURE_59:public network access stays ON (no VNet); blob-level public access is OFF and the blobs are private
  # checkov:skip=CKV_AZURE_206:LRS is deliberate ($10/month budget); an audit trail is not primary data
  # checkov:skip=CKV2_AZURE_1:diagnostic logs are not customer data; CMK on the log account is a later hardening item
  # checkov:skip=CKV2_AZURE_33:no private endpoint is reachable from the on-prem cluster; RBAC and private blobs are the boundary
  # checkov:skip=CKV2_AZURE_40:Azure Monitor's storage destination authenticates with the account key; shared keys cannot be disabled here
  name                            = "stqnsckvaudit"
  resource_group_name             = azurerm_resource_group.platform.name
  location                        = azurerm_resource_group.platform.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  access_tier                     = "Hot"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access           = "Enabled" # no VNet on-prem (same posture as the state account); the blobs are private and the name is not published
  tags                            = local.tags

  # Azure Monitor's storage destination authenticates with the account key;
  # disabling shared keys on a diagnostics destination is not supported. The
  # account is dedicated to audit logs (no other data), listed only by the four
  # diagnostic settings, and the blobs are private.
  shared_access_key_enabled = true

  # A SAS is never issued against this account; the policy exists so the
  # capability cannot quietly become an unbounded one.
  sas_policy {
    expiration_period = "1.00:00:00"
    expiration_action = "Log"
  }

  # A deleted log blob is recoverable for 30 days: the incident that makes the
  # trail matter is also the one that might delete it.
  blob_properties {
    delete_retention_policy {
      days = 30
    }
  }

  lifecycle {
    prevent_destroy = true # the audit trail outlives any stack rewrite
  }
}

# 1-year retention. The rule runs daily and removes blobs under the audit
# container only; nothing else ever lives in this account.
resource "azurerm_storage_management_policy" "kv_audit" {
  storage_account_id = azurerm_storage_account.kv_audit.id

  rule {
    name    = "expire-audit-logs"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["insights-logs-auditevent"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 365
      }
    }
  }
}

# One diagnostic setting per vault. AuditEvent is the data-plane category
# (secret/key/certificate reads, writes, deletes); it is the only category a
# Key Vault exposes.
resource "azurerm_monitor_diagnostic_setting" "kv_audit" {
  for_each = local.audit_vaults

  name               = "audit-to-storage"
  target_resource_id = each.value
  storage_account_id = azurerm_storage_account.kv_audit.id

  enabled_log {
    category = "AuditEvent"
  }
}
