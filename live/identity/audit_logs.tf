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
# Retention and tamper resistance: the container is WORM (a locked 365-day
# container-level time-based policy) and the lifecycle rule deletes its blobs
# after 365 days. The two use the same anchor (append blobs age from their LAST
# modification), so a blob is deletable exactly when its immutability expires.
# The policy sets protected_append_writes_enabled: Azure Monitor writes each
# hourly log file as an APPEND blob, and container-level WORM blocks Append
# Block unless that flag is on (Microsoft: "The Append Block operation is
# permitted only for policies with the allowProtectedAppendWrites property
# enabled"). Version-level WORM is what the Azure Monitor docs recommend and
# would not need the flag, but azurerm has no version-level resource.
# The policy is LOCKED: delete protection is exactly what an audit trail needs,
# and an unlocked policy provides none (Microsoft: "Unlocked policies don't
# provide delete protection"). Retention can only be increased afterwards.
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
  # Skips, one posture: this account holds audit LOGS, is reached only by Azure
  # Monitor and the owner's read-only queries, and the on-prem cluster has no
  # VNet to privatize into (same reason as the state account). Attribute-level
  # comments on purpose: checkov 3.3 does not honour a skip above the resource.
  # checkov:skip=CKV_AZURE_33:no queue/table service is used; the account holds only diagnostic blobs
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

  # Azure Monitor's storage destination uses the account key. The diagnostic-
  # settings documentation lists no Microsoft Entra/managed-identity
  # authentication for a storage-account destination (only "the destination
  # resource must already exist" and the trusted-Microsoft-services firewall
  # bypass), so shared keys stay ON. The account is dedicated to audit logs,
  # listed only by the four diagnostic settings, and the blobs are private.
  # Re-checked 2026-11-04 against
  # learn.microsoft.com/azure/azure-monitor/essentials/diagnostic-settings.
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

# The audit container Azure Monitor writes into. It is declared here so the
# WORM policy below has a stable resource id; Azure Monitor would create the
# same name on its first event, and an existing empty container is fine.
resource "azurerm_storage_container" "kv_audit" {
  # checkov:skip=CKV2_AZURE_21:the account's logging destination is Azure Monitor itself; blob read logging into the same account would loop
  name                  = "insights-logs-auditevent"
  storage_account_id    = azurerm_storage_account.kv_audit.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true # the audit trail outlives any stack rewrite
  }
}

# Locked, 365-day WORM for every blob in the container. Protected append writes
# are ENABLED so Azure Monitor can keep appending to the current hour's blob.
resource "azurerm_storage_container_immutability_policy" "kv_audit" {
  storage_container_resource_manager_id = azurerm_storage_container.kv_audit.id
  immutability_period_in_days           = 365
  protected_append_writes_enabled       = true
  locked                                = true
}

# 1-year retention. The rule runs daily and removes blobs under the audit
# container only; nothing else ever lives in this account.
resource "azurerm_storage_management_policy" "kv_audit" {
  storage_account_id = azurerm_storage_account.kv_audit.id

  # Deletion at 365 days is allowed only once the WORM policy above has
  # expired for that blob; both count from the blob's last modification.

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
