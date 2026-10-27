# ── Vault data-plane RBAC (§7.1) ────────────────────────────────────────────
#
# Azure RBAC DATA-PLANE roles only, and only on the four vault resources —
# never the resource group or the subscription (the static test in
# tests/static.sh fails any role or scope outside this shape):
#
#   grp-qnsc-platform-admins   Key Vault Secrets Officer on ALL FOUR vaults —
#                              the owner/operator writes every secret through
#                              stdin (§7: OpenTofu owns shape and access,
#                              never values).
#   QNSC ESO <env> (eso.tf)    Key Vault Secrets User on ITS OWN vault only
#                              (dev, prod, platform). Nothing on kv-qnsc-admin
#                              — no store reads it (§7.1).
#
# The group arrives by variable: grp-qnsc-platform-admins is hand-created (it
# is also the Cloudflare Access door-2 group, §7.2) and assigning the role
# needs only its object id — an identifier, not a credential, but it is
# operator-supplied all the same (TF_VAR_, never committed).

variable "platform_admins_object_id" {
  type        = string
  description = "Object id of the existing grp-qnsc-platform-admins Entra group. TF_VAR_platform_admins_object_id, never committed."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.platform_admins_object_id))
    error_message = "platform_admins_object_id must be an Entra object id (GUID)."
  }
}

locals {
  # The four vaults under one map: the three purge-protected ones plus dev.
  all_vaults = merge(
    { for k, v in azurerm_key_vault.purge_protected : k => v.id },
    { dev = azurerm_key_vault.dev.id },
  )
}

resource "azurerm_role_assignment" "admins_secrets_officer" {
  for_each = local.all_vaults

  scope                = each.value # a vault resource id — never the RG or subscription
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.platform_admins_object_id
  principal_type       = "Group" # tolerate replication lag between group creation and this assignment
}

# The ESO read path: Secrets User (get/list on secrets) — never Officer,
# never any wider than the one vault its store points at.
resource "azurerm_role_assignment" "eso_secrets_user" {
  for_each = local.eso

  scope                = local.eso[each.key].vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.eso[each.key].object_id
  principal_type       = "ServicePrincipal" # tolerate replication lag between SP creation and this assignment
}
