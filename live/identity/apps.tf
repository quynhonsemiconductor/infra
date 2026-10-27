# ── Product sign-in apps (ONPREM-PLAN §7.2, §8.2 — M-7) ─────────────────────
#
# One delegated-only sign-in app per product per env, named "<Product> <Env>".
# The EXISTING hand-made registrations are ADOPTED via the import blocks below
# (ids from the `existing_object_ids` variable, fed by CI repository
# variables) — no duplicates, no new client IDs.
#
# Rules (§7.2):
#   - delegated only: openid/profile/email/offline_access/User.Read (KB also
#     Files.Read.All + Sites.Read.All for its connectors). NEVER Mail.Send.
#   - callbacks are SERVER-side code flows → web.redirect_uris only; dev
#     loopbacks use the org's fixed dev-stack ports from
#     .github/docs/LOCAL-DEVELOPMENT.md (rova 5175, opshub 5174, KB 8000 —
#     WEB_DEV_PORT overrides Vite's 5173 default; KB keeps its defaults)
#     plus the KB connector callbacks
#     (`/api/v1/auth/entra/callback`, src/api/routers/auth.py:2721;
#     `/api/v1/connectors/oauth/callback`, src/api/routers/connectors.py:440).
#   - client-secret VALUES never touch state (§7, main.tf): the owner rotates
#     with scripts/rotate-signin-secret.sh (az ad app credential reset --append
#     --end-date +6 months, piped straight into the vault, nothing printed)
#     and the weekly
#     expiry-check watches the vault's expires tag. Tofu owns shape only.
#   - app_role_assignment_required = FALSE everywhere, deliberately: flipping
#     it on without assignments would lock out current sign-ins — including
#     rova prod ON AWS TODAY. Login gating is Access + Entra groups, a later
#     explicit decision (owner OK required before anyone turns this on).
#   - owners: the CI service principal + one SECOND company owner (CI
#     variables). No personal-only ownership.

data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000" # well-known, not a secret
}

locals {
  # Scope NAMES → the msgraph SP's delegated (oauth2) permission ids, resolved
  # at plan time instead of hardcoded UUIDs.
  graph_scopes = {
    openid         = "openid"
    profile        = "profile"
    email          = "email"
    offline_access = "offline_access"
    User_Read      = "User.Read"
    Files_Read_All = "Files.Read.All"
    Sites_Read_All = "Sites.Read.All"
  }

  signin_apps = {
    rova_prod = {
      display_name  = "Rova Prod"
      redirect_uris = ["https://rova.qnsc.vn/api/auth/callback/microsoft"]
      loopbacks     = []
      scopes        = ["openid", "profile", "email", "offline_access", "User_Read"]
    }
    rova_dev = {
      display_name  = "Rova Dev"
      redirect_uris = ["https://rova-dev.qnsc.vn/api/auth/callback/microsoft", "http://localhost:5175/api/auth/callback/microsoft"]
      loopbacks     = []
      scopes        = ["openid", "profile", "email", "offline_access", "User_Read"]
    }
    opshub_dev = {
      display_name  = "Opshub Dev"
      redirect_uris = ["https://opshub-dev.qnsc.vn/api/auth/callback/microsoft", "http://localhost:5174/api/auth/callback/microsoft"]
      loopbacks     = []
      scopes        = ["openid", "profile", "email", "offline_access", "User_Read"]
    }
    kb_dev = {
      display_name = "KB Dev"
      redirect_uris = [
        "https://kb-dev.qnsc.vn/api/v1/auth/entra/callback",
        "https://kb-dev.qnsc.vn/api/v1/connectors/oauth/callback",
        "http://localhost:8000/api/v1/auth/entra/callback",
        "http://localhost:8000/api/v1/connectors/oauth/callback",
      ]
      loopbacks = []
      scopes    = ["openid", "profile", "email", "offline_access", "User_Read", "Files_Read_All", "Sites_Read_All"]
    }
  }
}

variable "existing_object_ids" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "Object ids of the EXISTING hand-made application registrations (adopted, not replaced). GitHub Actions repository variable TF_VAR_existing_object_ids (JSON)."
}

variable "existing_sp_object_ids" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "Object ids of the existing service principals, same source."
}

variable "ci_sp_object_id" {
  type        = string
  description = "Object id of the 'QNSC CI Infra' service principal — co-owner of every app. GitHub Actions repository variable."
}

variable "second_owner_object_id" {
  type        = string
  description = "Object id of the second company owner (A4/O2). GitHub Actions repository variable."
}

resource "azuread_application" "signin" {
  for_each = local.signin_apps

  display_name     = each.value.display_name
  sign_in_audience = "AzureADMyOrg"

  web {
    redirect_uris = each.value.redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  # Delegated Graph scopes only; ids resolved from the msgraph SP (no literals).
  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = each.value.scopes
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[local.graph_scopes[resource_access.value]]
        type = "Scope"
      }
    }
  }

  owners = [var.ci_sp_object_id, var.second_owner_object_id]
}

# ── Adoption: import the existing registrations, do not create new ones ─────
import {
  to = azuread_application.signin["rova_prod"]
  id = "/applications/${var.existing_object_ids.rova_prod}"
}
import {
  to = azuread_application.signin["rova_dev"]
  id = "/applications/${var.existing_object_ids.rova_dev}"
}
import {
  to = azuread_application.signin["opshub_dev"]
  id = "/applications/${var.existing_object_ids.opshub_dev}"
}
import {
  to = azuread_application.signin["kb_dev"]
  id = "/applications/${var.existing_object_ids.kb_dev}"
}
import {
  to = azuread_service_principal.signin["rova_prod"]
  id = "/servicePrincipals/${var.existing_sp_object_ids.rova_prod}"
}
import {
  to = azuread_service_principal.signin["rova_dev"]
  id = "/servicePrincipals/${var.existing_sp_object_ids.rova_dev}"
}
import {
  to = azuread_service_principal.signin["opshub_dev"]
  id = "/servicePrincipals/${var.existing_sp_object_ids.opshub_dev}"
}
import {
  to = azuread_service_principal.signin["kb_dev"]
  id = "/servicePrincipals/${var.existing_sp_object_ids.kb_dev}"
}

resource "azuread_service_principal" "signin" {
  for_each = azuread_application.signin

  # FALSE, deliberately: `app_role_assignment_required = true` without
  # assignments locks out every existing sign-in, including rova prod on AWS
  # TODAY. Revisit only with the owner's explicit OK (then add the
  # azuread_app_role_assignment group grants in the same PR).
  app_role_assignment_required = false
  client_id                    = each.value.client_id
  owners                       = [var.ci_sp_object_id, var.second_owner_object_id]
}

output "signin_app_client_ids" {
  description = "Client (application) IDs for the products' MICROSOFT_CLIENT_ID values. Never carries a secret."
  value       = { for k, app in azuread_application.signin : k => app.client_id }
}
