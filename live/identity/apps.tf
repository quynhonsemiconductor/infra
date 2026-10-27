# ── Product sign-in apps (ONPREM-PLAN §7.2, §8.2 — M-7) ─────────────────────
#
# One delegated-only sign-in app per product per env, named "<Product> <Env>".
# The EXISTING hand-made registrations are ADOPTED via the import blocks below
# (ids passed by the owner at apply time, README "Sign-in apps") — no
# duplicates, no new client IDs.
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
#   - app_role_assignment_required: FALSE for rova/opshub-prod/kb — flipping
#     it ON without assignments would lock out current sign-ins, including
#     rova prod ON AWS TODAY. opshub Dev keeps the LIVE value TRUE (owner
#     decision 2026-10-18): Entra admits only the `opshub-users` dynamic group,
#     assigned with the `employee` App Role below. Never flip opshub_dev to
#     false — that would open the app to the whole tenant.
#   - owners: the owner operator + one SECOND company owner only. NO CI
#     identity — an owner could add credentials/redirects to these apps; CI
#     must never be able to.

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
      display_name = "Rova Prod"
      redirect_uris = [
        "https://rova.qnsc.vn/api/auth/callback/microsoft",
        # v7 BFF rollback URI (rova infra/modules/stack/main.tf ENTRA_REDIRECT_URI) —
        # kept until the identity-v8 runbook retires the rollback, day 7.
        "https://rova.qnsc.vn/v1/bff/callback",
      ]
      assignment_required = false
      scopes              = ["openid", "profile", "email", "offline_access", "User_Read"]
    }
    rova_dev = {
      display_name        = "Rova Dev"
      redirect_uris       = ["https://rova-dev.qnsc.vn/api/auth/callback/microsoft", "http://localhost:5175/api/auth/callback/microsoft"]
      assignment_required = false
      scopes              = ["openid", "profile", "email", "offline_access", "User_Read"]
    }
    opshub_dev = {
      display_name        = "Opshub Dev"
      redirect_uris       = ["https://opshub-dev.qnsc.vn/api/auth/callback/microsoft", "http://localhost:5174/api/auth/callback/microsoft"]
      assignment_required = true # LIVE value (owner decision 2026-10-18): gate = opshub-users group + employee role
      scopes              = ["openid", "profile", "email", "offline_access", "User_Read"]
    }
    kb_dev = {
      display_name = "KB Dev"
      redirect_uris = [
        # AWS-era ECS URIs (kb infra/modules/stack/main.tf MICROSOFT_LOGIN_REDIRECT_URI /
        # MICROSOFT_REDIRECT_URI) — already the same paths; kept verbatim until the
        # on-prem cutover PR removes anything.
        "https://kb-dev.qnsc.vn/api/v1/auth/entra/callback",
        "https://kb-dev.qnsc.vn/api/v1/connectors/oauth/callback",
        "http://localhost:8000/api/v1/auth/entra/callback",
        "http://localhost:8000/api/v1/connectors/oauth/callback",
      ]
      assignment_required = false
      scopes              = ["openid", "profile", "email", "offline_access", "User_Read", "Files_Read_All", "Sites_Read_All"]
    }
  }

  # The Opshub Dev App Roles, exactly as they exist on the live registration
  # (values and display names from db/permissions.catalog.ts ROLE / ROLE_NAMES;
  # descriptions from the owner's `az ad app show` export — see README). The
  # role IDS come in as a variable (identifiers, not secrets — but owner-
  # supplied, never committed). Modeling them here is what keeps the import
  # from DELETING them: azuread 3.x does not treat app_roles as Computed.
  opshub_app_roles = {
    admin    = { display_name = "Platform Administrator", description = "Full administrative access to Opshub." }
    it-admin = { display_name = "IT Administrator", description = "Manages devices, integrations and IT operations." }
    security = { display_name = "Security Officer", description = "Security posture, incident and access-review duties." }
    hr       = { display_name = "HR Manager", description = "People records, onboarding and offboarding." }
    manager  = { display_name = "People Manager", description = "Team-level management duties (approvals, ratings)." }
    helpdesk = { display_name = "Help Desk", description = "Support-tier access for employee requests." }
    auditor  = { display_name = "Auditor (read-only)", description = "Read-only access for audit and compliance." }
    employee = { display_name = "Employee", description = "Baseline role assigned to the opshub-users dynamic group." }
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

variable "owner_operator_object_id" {
  type        = string
  description = "Object id of the owner operator (A4/O2) — co-owner of every app. TF_VAR_owner_operator_object_id, never committed. Deliberately NOT a CI identity: an owner can add credentials to these apps; CI never may."
}

variable "opshub_dev_app_role_ids" {
  type = object({
    admin    = string
    it-admin = string
    security = string
    hr       = string
    manager  = string
    helpdesk = string
    auditor  = string
    employee = string
  })
  description = "App Role ids (GUIDs) of the LIVE Opshub Dev registration, from the owner's `az ad app show` export (README). TF_VAR_opshub_dev_app_role_ids (JSON), never committed."

  validation {
    condition = alltrue([
      for id in values(var.opshub_dev_app_role_ids) :
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id))
    ])
    error_message = "Every opshub_dev_app_role_ids value must be a GUID."
  }
}

variable "opshub_dev_app_role_descriptions" {
  type = object({
    admin    = string
    it-admin = string
    security = string
    hr       = string
    manager  = string
    helpdesk = string
    auditor  = string
    employee = string
  })
  description = "Exact `description` of each live Opshub Dev App Role, from the owner's `az ad app show` export (README) — hand-written text here would overwrite the live values. TF_VAR_opshub_dev_app_role_descriptions (JSON), never committed."

  validation {
    condition = alltrue([
      for d in values(var.opshub_dev_app_role_descriptions) : can(regex("^\\S.*", d))
    ])
    error_message = "Every opshub_dev_app_role_descriptions value must be a non-empty string."
  }
}

variable "existing_identifier_uris" {
  type        = map(list(string))
  default     = {}
  description = "Identifier URIs of the LIVE registrations, keyed like local.signin_apps, from the owner's `az ad app show` export (README). Empty = the app has none — pass {} ONLY if the export shows none; an omitted live identifierUri would otherwise be removed by the apply. TF_VAR_existing_identifier_uris (JSON)."
}

variable "second_owner_object_id" {
  type        = string
  description = "Object id of the second company owner (A4/O2). GitHub Actions repository variable."
}

resource "azuread_application" "signin" {
  for_each = local.signin_apps

  display_name     = each.value.display_name
  sign_in_audience = "AzureADMyOrg"
  # From the owner's export: an omitted live identifierUri WOULD be removed on
  # apply — the go/no-go in the README is "no changes on an imported app
  # outside the ones named in the PR body".
  identifier_uris = try(var.existing_identifier_uris[each.key], [])

  web {
    redirect_uris = each.value.redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  # The Opshub Dev App Roles, modeled INLINE so the apply writes them instead
  # of removing them (azuread 3.x does not treat app_roles as Computed; a
  # standalone resource would first strip them, then re-add — fighting every
  # apply). ids and descriptions from the export via variables; opshub_dev
  # only, the other apps have none.
  dynamic "app_role" {
    for_each = each.key == "opshub_dev" ? local.opshub_app_roles : {}
    content {
      id                   = var.opshub_dev_app_role_ids[app_role.key]
      allowed_member_types = ["User"]
      description          = var.opshub_dev_app_role_descriptions[app_role.key]
      display_name         = app_role.value.display_name
      enabled              = true
      value                = app_role.key
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

  owners = [var.owner_operator_object_id, var.second_owner_object_id]
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

  # Per-app (see local.signin_apps): false keeps rova/opshub-prod/kb open as
  # they are today; opshub_dev stays TRUE — the live access gate (opshub-users
  # dynamic group + employee role). Never flip opshub_dev to false.
  app_role_assignment_required = each.value.assignment_required
  client_id                    = each.value.client_id
  owners                       = [var.owner_operator_object_id, var.second_owner_object_id]
}

output "signin_app_client_ids" {
  description = "Client (application) IDs for the products' MICROSOFT_CLIENT_ID values. Never carries a secret."
  value       = { for k, app in azuread_application.signin : k => app.client_id }
}
