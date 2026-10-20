# ── live/identity — Entra ID + Key Vault (§7, §11.3) ────────────────────────
#
# PREPARATION: applies nothing yet — there is no subscription. This file pins
# the concrete, decided resources; the Entra application objects land as real
# blocks in Phase 1 once the tenant objects can be created and read back.
#
# What this stack OWNS (applied in this order once the subscription exists):
#
#   done below   the resource group, the four Key Vaults with the §7.1
#                properties, the $10 subscription budget alert
#
#   Phase 1      azuread: groups (grp-qnsc-platform-admins, grp-qnsc-developers,
#                grp-qnsc-rova-vendors, grp-qnsc-kv-dev-officers); the ESO SP
#                apps x3 (certificate only — public certs committed in infra/),
#                CI apps x2 (QNSC CI Infra / Read with federated credentials on
#                the infra GitHub environment), the Backup Prod app; product
#                sign-in apps' redirect URIs per §8.2 (loopback on dev only);
#                Key Vault RBAC role assignments (ESO Secrets User, CI Reader)
#
#   imported     stqnsctfstate — created BY HAND (pre-work (e)), then
#                `tofu import` into this stack; never created by TF, because
#                the state backend must exist before TF can hold state
#
# Rules this stack never breaks (§7):
#   - OpenTofu owns SHAPE and ACCESS, never values. No secret, token, key or
#     password is ever set here.
#   - Certificates are attached by their PUBLIC half, committed in infra/.
#   - Client secrets are created outside state (dashboard/az) and piped into
#     the vaults through stdin with expiry + owner/rotate-by tags.

resource "azurerm_resource_group" "platform" {
  name     = "rg-qnsc-platform"
  location = var.location
  tags     = local.tags
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

  vaults = {
    prod = {
      name             = "kv-qnsc-prod"
      purge_protection = true
    }
    dev = {
      name             = "kv-qnsc-dev"
      purge_protection = false
    }
    platform = {
      name             = "kv-qnsc-platform"
      purge_protection = true
    }
    admin = {
      name             = "kv-qnsc-admin"
      purge_protection = true
    }
  }
}

resource "azurerm_key_vault" "vaults" {
  for_each = local.vaults

  name                          = each.value.name
  location                      = azurerm_resource_group.platform.location
  resource_group_name           = azurerm_resource_group.platform.name
  tenant_id                     = data.azuread_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 90
  purge_protection_enabled      = each.value.purge_protection
  public_network_access_enabled = true

  # Network rules: open by default for now — the ESO SPs and CI identities are
  # the RBAC boundary, and the vaults must be reachable from the office IP and
  # from GitHub's OIDC flows. Locking down to named networks is a §9 hardening
  # step with its own trigger, not day-one work.
  tags = local.tags
}

data "azuread_client_config" "current" {}

# ── The budget alert (pre-work (e)) ─────────────────────────────────────────
#
# $10/month on the subscription; alert to Teams + devops@ via the action group
# that live/observability-alerting owns. The budget is on the SUBSCRIPTION,
# not the resource group — the point is "Azure is spending money at all".
resource "azurerm_consumption_budget_subscription" "ten_dollars" {
  name            = "budget-qnsc-10usd"
  subscription_id = var.subscription_id
  amount          = 10
  time_grain      = "Monthly"

  time_period {
    # must be the first of a month, ≤ 12 months out (provider rule)
    start_date = var.budget_period_start
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThanOrEqualTo"
    contact_emails = ["devops@qnsc.vn"]
  }

  notification {
    enabled        = true
    threshold_type = "Forecasted"
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    contact_emails = ["devops@qnsc.vn"]
  }
}
