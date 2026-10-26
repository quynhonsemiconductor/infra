# ── The state backend (created by hand, pre-work (e)) ───────────────────────
#
# stqnsctfstate and its `tfstate` container MUST exist before tofu can hold
# any state, so they were created BY HAND and are imported (imports.tf), never
# created. Every setting below mirrors the hand-run commands exactly — the
# first plan after the import must show NO change on either resource. Changing
# any of them would be an in-place update to the thing holding every state
# file; losing it loses all of them — hence prevent_destroy on both.
#
#   StorageV2 / Standard_LRS, access tier Hot, HTTPS-only, TLS 1.2 minimum,
#   blob public access OFF, shared keys OFF (backend uses Entra, versions.tf),
#   cross-tenant replication OFF, no HNS/SFTP/NFS, NO tags,
#   versioning + 30-day blob/container soft delete (blob_properties below —
#   in azurerm 5.x these data-protection settings live on the account).
resource "azurerm_storage_account" "tfstate" {
  # Skips, all one posture (same as the vaults' CKV_AZURE_189 reason): the
  # backend is reached from GitHub OIDC and the office LAN, the on-prem
  # cluster has NO VNet, and RBAC on the account (CI apply/Read identities,
  # §7.4) is the access boundary. §9 hardening owns diagnostics/CMK later.
  # checkov:skip=CKV_AZURE_33:classic blob analytics logging is not wired; state access is audited through Entra sign-in + role assignments; diagnostics = §9 hardening trigger
  # checkov:skip=CKV_AZURE_59:queue/table logging — this account holds only tfstate blobs, no queue or table data; diagnostics = §9 hardening trigger
  # checkov:skip=CKV2_AZURE_1:account-level public network access stays ON (no VNet to privatize into) — blob public access is OFF and RBAC is the boundary (§7.4)
  # checkov:skip=CKV2_AZURE_21:on-prem k3s has no VNet - no private endpoint/IP allowlist is reachable; RBAC is the boundary
  # checkov:skip=CKV_AZURE_206:state files are platform config, not customer data; CMK on the state account is a §9 hardening item
  # checkov:skip=CKV2_AZURE_33:LRS is deliberate ($10/month budget): state is reproducible from git + re-apply
  name                             = "stqnsctfstate"
  resource_group_name              = azurerm_resource_group.platform.name
  location                         = azurerm_resource_group.platform.location
  account_kind                     = "StorageV2"
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  access_tier                      = "Hot"
  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"
  allow_nested_items_to_be_public  = false
  shared_access_key_enabled        = false
  cross_tenant_replication_enabled = false
  public_network_access            = "Enabled" # the backend is reached from GitHub OIDC and the office LAN; RBAC is the boundary (§7.4)
  # NOT set, on purpose: local_user_enabled. Azure leaves isLocalUserEnabled
  # unset on the hand-created account; azurerm 5.x defaults it to true and
  # reads unset as true, so omitting it is the no-change choice (setting
  # `false` would be a diff).
  # public_network_access: Azure leaves it unset (null) too, while azurerm 5.x
  # plans "" -> "Enabled" — the owner runs one idempotent `az storage account
  # update --public-network-access Enabled` before the first plan (README step
  # 2), after which Azure reports Enabled and the plan is clean.

  # Versioning + 30-day soft delete for blobs AND containers — the recovery
  # path for a deleted or overwritten state version. No change feed, no
  # last-access-time tracking (both unset in Azure).
  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  # NO tags: the hand-created account has none, and the first plan must be a
  # clean no-change.

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  # checkov:skip=CKV2_AZURE_21:blob analytics logging is not wired (same posture as the account above); state access is audited through Entra + role assignments; diagnostics = §9 hardening trigger
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}
