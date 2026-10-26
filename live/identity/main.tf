# ── live/identity — Entra ID + Key Vault (§7, §11.3) ────────────────────────
#
# What this stack OWNS (applied in this order once the subscription exists):
#
#   done below   the resource group, the four Key Vaults with the §7.1
#                properties, the $10 subscription budget alert, the two CI
#                identities ("QNSC CI Infra" / "QNSC CI Infra Read", §7.4)
#
#   Phase 1      azuread: groups (grp-qnsc-platform-admins, grp-qnsc-developers,
#                grp-qnsc-rova-vendors, grp-qnsc-kv-dev-officers); the ESO SP
#                apps x3 (certificate only — public certs committed in infra/),
#                the Backup Prod app; product sign-in apps' redirect URIs per
#                §8.2 (loopback on dev only); Key Vault RBAC role assignments
#                (ESO Secrets User, CI Reader)
#
#   imported     rg-qnsc-platform, stqnsctfstate and its `tfstate` container
#                (blob-service properties live on the account resource) and
#                the qnsc-platform-monthly budget —
#                all created BY HAND (pre-work (e); the state backend and its
#                resource group must exist before TF can hold any state), then
#                imported via the blocks in imports.tf. Each block here is an
#                import target, never a creation path: a plan after import
#                must show NO change on any imported resource. The RG and the
#                storage account carry no tags in Azure — code matches.
#
# Rules this stack never breaks (§7):
#   - OpenTofu owns SHAPE and ACCESS, never values. No secret, token, key or
#     password is ever set here.
#   - Certificates are attached by their PUBLIC half, committed in infra/.
#   - Client secrets are created outside state (dashboard/az) and piped into
#     the vaults through stdin with expiry + owner/rotate-by tags.

# Import target (imports.tf): the backend needs it before tofu can hold any
# state, so it was created by hand. prevent_destroy — deleting it would take
# the state backend with it. NO tags: the hand-created RG has none, and the
# first plan must be a clean no-change.
resource "azurerm_resource_group" "platform" {
  name     = "rg-qnsc-platform"
  location = var.location

  lifecycle {
    prevent_destroy = true
  }
}

# ── The four vaults (§7.1) ──────────────────────────────────────────────────
#
#   kv-qnsc-prod      QNSC ESO Prod (Secrets User) reads; purge protection ON
#   kv-qnsc-dev       QNSC ESO Dev + dev officers; purge protection off (dev
#                     secrets are re-issuable; prod/platform/admin are not)
#   kv-qnsc-platform  QNSC ESO Platform; purge protection ON
#   kv-qnsc-admin     break-glass + bootstrap; NO store syncs from it; purge
#                     protection ON
#
# All four: Azure RBAC permissions model (never access policies), 90-day soft
# delete, every secret created later carries an expiry + owner/rotate-by tag.

locals {
  tags = {
    managed-by = "opentofu"
    stack      = "live/identity"
  }

  # Network checks (CKV_AZURE_189/109, CKV2_AZURE_32) are skipped on BOTH
  # resources, with one reason: the vault is reached from the office LAN and
  # from GitHub's OIDC flows, and the on-prem cluster has NO VNet — a private
  # endpoint or IP allowlist cannot be attached to it. The RBAC boundary
  # (QNSC ESO <env>, CI Read = metadata only) is the access control; network
  # lockdown is §9 hardening with its own trigger.
  purge_protected = {
    prod     = { name = "kv-qnsc-prod" }
    platform = { name = "kv-qnsc-platform" }
    admin    = { name = "kv-qnsc-admin" }
  }
}

# Three of the four vaults (§7.1: purge protection on prod, platform, admin).
resource "azurerm_key_vault" "purge_protected" {
  for_each = local.purge_protected

  # checkov:skip=CKV_AZURE_189:on-prem k3s has no VNet - no private endpoint/IP allowlist is reachable; RBAC is the boundary (§9 hardening has the trigger)
  # checkov:skip=CKV_AZURE_109:same reason as CKV_AZURE_189
  # checkov:skip=CKV2_AZURE_32:same reason as CKV_AZURE_189

  name                          = each.value.name
  location                      = azurerm_resource_group.platform.location
  resource_group_name           = azurerm_resource_group.platform.name
  tenant_id                     = data.azuread_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 90
  purge_protection_enabled      = true
  public_network_access_enabled = true
  tags                          = local.tags

  # ALWAYS emitted: network_acls is Optional+Computed in azurerm — removing
  # the block would leave the last Deny behind. Empty office_ip renders
  # Allow + no rules = the pre-allowlist posture.
  network_acls {
    default_action = local.office_ip_enabled ? "Deny" : "Allow"
    bypass         = "AzureServices"
    ip_rules       = local.office_ip_enabled ? [var.office_ip] : []
  }
}

# kv-qnsc-dev — purge protection deliberately OFF (§7.1): Phase 1 iterates on
# the dev vault, and dev secret VALUES are re-issuable; soft delete (90 days)
# still protects against accidents.
resource "azurerm_key_vault" "dev" {
  # checkov:skip=CKV_AZURE_189:on-prem k3s has no VNet - no private endpoint/IP allowlist is reachable; RBAC is the boundary (§9 hardening has the trigger)
  # checkov:skip=CKV_AZURE_109:same reason as CKV_AZURE_189
  # checkov:skip=CKV2_AZURE_32:same reason as CKV_AZURE_189
  # checkov:skip=CKV_AZURE_110:dev is deliberately purge-unprotected during Phase-1 iteration; secrets are re-issuable, soft delete covers accidents
  # checkov:skip=CKV_AZURE_42:same reason as CKV_AZURE_110 (soft delete is enabled; purge protection is the dev exception)
  name                          = "kv-qnsc-dev"
  location                      = azurerm_resource_group.platform.location
  resource_group_name           = azurerm_resource_group.platform.name
  tenant_id                     = data.azuread_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 90
  purge_protection_enabled      = false
  public_network_access_enabled = true
  tags                          = local.tags

  # ALWAYS emitted: network_acls is Optional+Computed in azurerm — removing
  # the block would leave the last Deny behind. Empty office_ip renders
  # Allow + no rules = the pre-allowlist posture.
  network_acls {
    default_action = local.office_ip_enabled ? "Deny" : "Allow"
    bypass         = "AzureServices"
    ip_rules       = local.office_ip_enabled ? [var.office_ip] : []
  }
}

data "azuread_client_config" "current" {}

# ── The budget alert (pre-work (e)) ─────────────────────────────────────────
#
# $10/month on the subscription; alert to devops@qnsc.vn. The budget is on the
# SUBSCRIPTION, not the resource group — the point is "Azure is spending money
# at all". Created by hand as `qnsc-platform-monthly` (pre-work (e)) and
# imported (imports.tf): the name matches so the import is in-place, never a
# duplicate or a replace. Every field below mirrors the hand-created budget
# EXACTLY (Cost budget — the provider always writes category Cost —,
# GreaterThan on all four alerts, 2026-10-01 → 2028-09-30 window): the first
# plan must show no change on it.
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "qnsc-platform-monthly"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = 10
  time_grain      = "Monthly"

  time_period {
    start_date = var.budget_period_start
    end_date   = var.budget_period_end
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    contact_emails = ["devops@qnsc.vn"]
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    contact_emails = ["devops@qnsc.vn"]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    contact_emails = ["devops@qnsc.vn"]
  }

  notification {
    enabled        = true
    threshold_type = "Forecasted"
    threshold      = 100
    operator       = "GreaterThan"
    contact_emails = ["devops@qnsc.vn"]
  }
}

# ── Office-IP allowlists (OPTIONAL — owner decision 2026-10-25) ─────────────

locals {
  office_ip_enabled = var.office_ip != ""
}

# Variable lives in variables.tf. The network_acls blocks are ALWAYS emitted
# (Optional+Computed — removing the block would leave the last Deny behind):
# **Deny only when office_ip is set** — empty renders Allow + no rules, the
# pre-allowlist posture. Data plane for machine credentials only; humans
# stay on Entra + MFA. Enable only after the line is stable (CUTOVER §4.4
# soak); runbook §7.7.
