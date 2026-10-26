# ── The state backend (created by hand, pre-work (e)) ───────────────────────
#
# stqnsctfstate and its `tfstate` container MUST exist before tofu can hold
# any state, so they were created BY HAND and are imported (imports.tf), never
# created. Every setting below mirrors the hand-run commands exactly — the
# first plan after the import must show NO change on either resource. Changing
# any of them would be an in-place update to the thing holding every state
# file; losing it loses all of them — hence prevent_destroy on both.
#
#   Standard_LRS / StorageV2, HTTPS-only, TLS 1.2 minimum,
#   blob public access OFF, shared keys OFF (backend uses Entra, versions.tf),
#   blob + container versioning/soft delete 30 days (blob_properties below —
#   in azurerm 5.x these data-protection settings live on the account).
resource "azurerm_storage_account" "tfstate" {
  name                            = "stqnsctfstate"
  resource_group_name             = azurerm_resource_group.platform.name
  location                        = azurerm_resource_group.platform.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access           = "Enabled" # the backend is reached from GitHub OIDC and the office LAN; RBAC is the boundary (§7.4)
  tags                            = local.tags

  # Versioning + 30-day soft delete for blobs AND containers — the recovery
  # path for a deleted or overwritten state version.
  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}
