# ── The Cloudflare Access IdP app (§7.2) ────────────────────────────────────
#
# "QNSC Cloudflare Access" is the Entra app behind EVERY Zero Trust door:
# live/edge configures the `entra` identity provider from its client id and a
# client secret, and every Access application (admin doors, dev hosts, MCP
# endpoints) lists that IdP. It was the only sign-in app outside this stack
# (2026-11-06 drift audit, Med), so it is ADOPTED here — app, service
# principal and the tenant-wide (AllPrincipals) delegated grant — with import
# blocks. No other object is created.
#
# The CREDENTIAL is untouched. §7 keeps secret VALUES out of state: the app
# carries one credential today ("cf-access-idp-2026-10", expires 2027-10-28),
# created by hand and stored in the vault + the infra repo secret that
# live/edge reads. Nothing in this file creates, rotates or removes it.
# Two consequences the owner must know:
#
#   - that credential is 12 months, while scripts/rotate-idp-secret.sh issues
#     +6 months (the §7.5 policy). Rotate it with that script at the next
#     rotation window so the live credential comes back inside the rule; the
#     weekly expiry watch already sees it;
#   - importing the app does NOT touch its owners' ability to add credentials:
#     the two company owners named below already own the app live. The SP had
#     NO owners, so the only planned change on import is the two SP owners.
#
# Delegated scopes are exactly the live set: openid, email, profile,
# offline_access, User.Read and GroupMember.Read.All. The last one is what
# `support_groups = true` on the edge IdP needs to match Entra groups in
# Access policies. Keep this list and the AllPrincipals grant in step: the
# grant resource REPLACES claim_values on apply.
#
# Object ids come from the owner kit (scripts/owner/identity-env), never from
# Git (public repo): TF_VAR_cf_access_object_ids.

variable "cf_access_object_ids" {
  type = object({
    application       = string
    service_principal = string
    grant             = string
  })
  description = "Object ids of the live 'QNSC Cloudflare Access' app and its service principal, plus the id of its AllPrincipals Graph delegated grant. Built by scripts/owner/identity-env/identity-env.sh; TF_VAR_cf_access_object_ids, never committed."

  validation {
    condition = (
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.cf_access_object_ids.application)) &&
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.cf_access_object_ids.service_principal))
    )
    error_message = "cf_access_object_ids.application and .service_principal must be Entra object ids (GUIDs)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9_=-]+$", var.cf_access_object_ids.grant))
    error_message = "cf_access_object_ids.grant must be a Graph oauth2PermissionGrant id (opaque, no slashes)."
  }
}

locals {
  # The delegated set the app requests AND the tenant-wide grant carries.
  # Web redirect: the single callback Cloudflare Access registers for the
  # Entra IdP (same hostname as the Access team domain).
  cf_access_redirect_uris = ["https://qnsc.cloudflareaccess.com/cdn-cgi/access/callback"]
  cf_access_scopes        = ["openid", "email", "profile", "offline_access", "User.Read", "GroupMember.Read.All"]
}

resource "azuread_application" "cf_access" {
  display_name     = "QNSC Cloudflare Access"
  sign_in_audience = "AzureADMyOrg" # single tenant; the Access IdP is an internal sign-in method

  web {
    redirect_uris = local.cf_access_redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  # Delegated Graph scopes only; ids resolved from the msgraph SP (no literals).
  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = local.cf_access_scopes
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[resource_access.value]
        type = "Scope"
      }
    }
  }

  # THE two company owners. The app already has exactly these two live, so an
  # import plans NO change here; the SP below gains them (it has none today).
  owners = [var.owner_operator_object_id, var.second_owner_object_id]
}

resource "azuread_service_principal" "cf_access" {
  client_id                    = azuread_application.cf_access.client_id
  app_role_assignment_required = false

  # ADDED on import: the live SP has no owners, so nobody owns the enterprise
  # app even though the app registration has two owners. Same two people.
  owners = [var.owner_operator_object_id, var.second_owner_object_id]
}

# The tenant-wide delegated consent. It is imported, never created: every user
# signing in through Access already relies on it. claim_values is replaced on
# apply, so it must equal the live scope list (above).
resource "azuread_service_principal_delegated_permission_grant" "cf_access" {
  service_principal_object_id          = azuread_service_principal.cf_access.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = local.cf_access_scopes
}

import {
  to = azuread_application.cf_access
  id = "/applications/${var.cf_access_object_ids.application}"
}

import {
  to = azuread_service_principal.cf_access
  id = "/servicePrincipals/${var.cf_access_object_ids.service_principal}"
}

import {
  to = azuread_service_principal_delegated_permission_grant.cf_access
  id = "/oauth2PermissionGrants/${var.cf_access_object_ids.grant}"
}
