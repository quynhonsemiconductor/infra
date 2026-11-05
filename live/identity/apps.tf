# ── Product sign-in apps (ONPREM-PLAN §7.2, §8.2 — M-7) ─────────────────────
#
# One delegated-only sign-in app per product per env, named "<Product> <Env>".
# The EXISTING hand-made registrations are ADOPTED via the import blocks below
# (ids passed by the owner at apply time, README "Sign-in apps") — no
# duplicates, no new client IDs. This file is RECONCILED to the live exports
# (~/signin-export/*.json, 2026-10-27): everything below matches the live
# shape except the changes named in the PR body (the v8 callbacks, loopbacks,
# opshub's offline_access + User.Read, KB's email, the owners).
#
# Rules (§7.2):
#   - delegated Graph scopes + (rova) the User.Invite.All APPLICATION role for
#     the guest-invite flow — never Mail.Send (§7.2).
#   - callbacks are SERVER-side code flows → web.redirect_uris only; dev
#     loopbacks use the org's fixed dev-stack ports from
#     .github/docs/LOCAL-DEVELOPMENT.md (rova 5175, KB 8000 —
#     WEB_DEV_PORT overrides Vite's 5173 default; KB keeps its defaults).
#     opshub has NO loopback in this file — 5174 was never on the live app and
#     opshub's sign-in flows through the deployed URL only.
#   - client-secret VALUES never touch state (§7, main.tf): the owner rotates
#     with scripts/rotate-signin-secret.sh (az ad app credential reset --append
#     --end-date +6 months, piped straight into the vault, nothing printed)
#     and the weekly expiry watch (.github/workflows/secret-expiry.yml) reads the vault's expires tag. Tofu owns
#     shape only.
#   - app_role_assignment_required = FALSE everywhere, matching LIVE on all
#     four SPs (the old opshub-users/employee gate never shipped: the group
#     does not exist and opshub has no `employee` role — SA decision, YAGNI).
#   - owners: the owner operator + one SECOND company owner only (ADDED on
#     apply — live has none; named in the PR body). NO CI identity — an owner
#     could add credentials/redirects to these apps; CI must never be able to.

data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000" # well-known, not a secret
}

locals {
  # Scope names → { name, type } on the msgraph SP. Ids are resolved at plan
  # time from the SP data source (no literal UUIDs): Scope → the delegated
  # oauth2 permission ids, Role → the app-role ids (User.Invite.All for the
  # rova guest-invite flow, §7.2).
  graph_scopes = {
    openid          = { name = "openid", type = "Scope" }
    profile         = { name = "profile", type = "Scope" }
    email           = { name = "email", type = "Scope" }
    offline_access  = { name = "offline_access", type = "Scope" }
    User_Read       = { name = "User.Read", type = "Scope" }
    Files_Read      = { name = "Files.Read", type = "Scope" }
    Files_Read_All  = { name = "Files.Read.All", type = "Scope" }
    Sites_Read_All  = { name = "Sites.Read.All", type = "Scope" }
    User_Invite_All = { name = "User.Invite.All", type = "Role" }
  }

  # Reconciled to ~/signin-export/*.json (2026-10-27):
  #   rova_prod : live redirect is the v7 /v1/bff/callback — the v8
  #               /api/auth/callback/microsoft is the ADDED cutover URI.
  #   rova_dev  : live has /api/auth/callback/microsoft + /v1/bff/callback —
  #               the 5175 loopback is the ADDED dev URI.
  #   opshub    : display name "OpsHub Dev" (live); live redirect is the
  #               deployed callback only — the 5174 loopback was REMOVED from
  #               the plan (no local opshub sign-in flow uses it).
  #   kb        : the ECS live host kb-api-dev is replaced by the in-cluster
  #               kb-dev host (ONPREM-PLAN §8.2: the tunnel serves /api/* there);
  #               localhost:8000 is already live on both callbacks. The live
  #               AllPrincipals grant carries `email` (the app did not request
  #               it), so `email` is ADDED to the app — named in the PR body.
  signin_apps = {
    rova_prod = {
      display_name = "Rova Prod"
      redirect_uris = [
        "https://rova.qnsc.vn/v1/bff/callback",             # live; v7 rollback until day 7
        "https://rova.qnsc.vn/api/auth/callback/microsoft", # ADDED (v8 cutover)
      ]
      scopes          = ["openid", "profile", "email", "offline_access", "User_Read", "User_Invite_All"]
      optional_claims = ["email", "upn"] # live idToken claims (added at the v8 prod cutover)
    }
    rova_dev = {
      display_name = "Rova Dev"
      redirect_uris = [
        "https://rova-dev.qnsc.vn/api/auth/callback/microsoft", # live
        "https://rova-dev.qnsc.vn/v1/bff/callback",             # live
        "http://localhost:5175/api/auth/callback/microsoft",    # ADDED (dev loopback)
      ]
      scopes          = ["openid", "profile", "email", "offline_access", "User_Read", "User_Invite_All"]
      optional_claims = ["email", "upn", "preferred_username"] # live idToken claims
    }
    opshub_dev = {
      display_name    = "OpsHub Dev"
      redirect_uris   = ["https://opshub-dev.qnsc.vn/api/auth/callback/microsoft"]    # live; no loopback
      scopes          = ["openid", "profile", "email", "offline_access", "User_Read"] # live 3 + ADDED offline_access, User.Read
      optional_claims = ["email", "acct"]                                             # live idToken claims
    }
    kb_dev = {
      display_name = "KB Dev"
      redirect_uris = [
        "https://kb-dev.qnsc.vn/api/v1/auth/entra/callback", # in-cluster host (ONPREM-PLAN §8.2)
        "https://kb-dev.qnsc.vn/api/v1/connectors/oauth/callback",
        "http://localhost:8000/api/v1/auth/entra/callback", # live
        "http://localhost:8000/api/v1/connectors/oauth/callback",
      ]
      # Live 7 + ADDED email: the live AllPrincipals grant already carries
      # `email` although the app never requested it, so the derived grant set
      # must request it too or an apply revokes it (the guard below enforces
      # this for every app, not just KB).
      scopes          = ["openid", "profile", "email", "offline_access", "User_Read", "Files_Read", "Files_Read_All", "Sites_Read_All"]
      optional_claims = []
    }
  }

  # The OpsHub Dev App Roles, EXACTLY as on the live registration (export
  # 2026-10-27): 7 roles — there is NO `employee` role live (SA decision,
  # YAGNI). ids come in as a variable (identifiers, not secrets — owner-
  # supplied, never committed). Modeling them is what keeps the import from
  # DELETING them: azuread 3.x does not treat app_roles as Computed.
  opshub_app_roles = {
    admin    = { display_name = "Admin", allowed_member_types = ["User", "Application"], description = "Super admin" }
    it-admin = { display_name = "IT Administrator", allowed_member_types = ["User"], description = "Full IT operation access - assets, compliance, provisioning" }
    security = { display_name = "Security Officer", allowed_member_types = ["User"], description = "Compliance management and security posture access" }
    hr       = { display_name = "HR Manager", allowed_member_types = ["User"], description = "Employee lifecycle, leave approval, onboarding" }
    manager  = { display_name = "People Manager", allowed_member_types = ["User"], description = "Team lead - leave/overtime approval, access request view" }
    helpdesk = { display_name = "Help Desk", allowed_member_types = ["User"], description = "Asset management and access request triage" }
    auditor  = { display_name = "Auditor", allowed_member_types = ["User"], description = "Read-only audit log and compliance access" }
  }
}

variable "existing_object_ids" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "Object ids of the EXISTING hand-made application registrations (adopted, not replaced). TF_VAR_existing_object_ids exported by the owner, never committed."
}

variable "existing_sp_object_ids" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "Object ids of the existing service principals. TF_VAR_existing_sp_object_ids exported by the owner, never committed."
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
  })
  description = "App Role ids (GUIDs) of the LIVE OpsHub Dev registration, from the owner's `az ad app show` export (README) — 7 roles; there is no `employee` role live. TF_VAR_opshub_dev_app_role_ids (JSON), never committed."

  validation {
    condition = alltrue([
      for id in values(var.opshub_dev_app_role_ids) :
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id))
    ])
    error_message = "Every opshub_dev_app_role_ids value must be a GUID."
  }
}

variable "existing_identifier_uris" {
  type        = map(list(string))
  default     = {}
  description = "Identifier URIs of the LIVE registrations, keyed like local.signin_apps, from the owner's `az ad app show` export (README). The 2026-10-27 export shows NONE on all four apps — the default {} is correct; change it only if a future export shows one. TF_VAR_existing_identifier_uris (JSON)."
}

variable "second_owner_object_id" {
  type        = string
  description = "Object id of the second company owner (A4/O2). TF_VAR_second_owner_object_id exported by the owner, never committed."
}

resource "azuread_application" "signin" {
  for_each = local.signin_apps

  display_name     = each.value.display_name
  sign_in_audience = "AzureADMyOrg"
  # Live reads absent/None on all four; explicit ["None"] only where the
  # reconciliation notes name it (opshub/rova_dev) — same value as the
  # provider default, so either way the plan is clean.
  group_membership_claims = each.key == "opshub_dev" || each.key == "rova_dev" ? ["None"] : null
  # All four live apps have NO identifier URIs (export 2026-10-27) — the
  # default {} models that; the go/no-go in the README is "no changes on an
  # imported app outside the ones named in the PR body".
  identifier_uris = try(var.existing_identifier_uris[each.key], [])

  web {
    redirect_uris = each.value.redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  # Live idToken optional claims (export): opshub email+acct, rova_dev
  # email+upn+preferred_username, rova_prod email+upn; none on kb.
  dynamic "optional_claims" {
    for_each = length(each.value.optional_claims) > 0 ? [1] : []
    content {
      dynamic "id_token" {
        for_each = each.value.optional_claims
        content {
          name = id_token.value
        }
      }
    }
  }

  # The OpsHub Dev App Roles, modeled INLINE so the apply writes them instead
  # of removing them (azuread 3.x does not treat app_roles as Computed);
  # opshub_dev only, the other apps have none live.
  dynamic "app_role" {
    for_each = each.key == "opshub_dev" ? local.opshub_app_roles : {}
    content {
      id                   = var.opshub_dev_app_role_ids[app_role.key]
      allowed_member_types = app_role.value.allowed_member_types
      description          = app_role.value.description
      display_name         = app_role.value.display_name
      enabled              = true
      value                = app_role.key
    }
  }

  # Delegated Graph scopes (+ rova's User.Invite.All application role); ids
  # resolved from the msgraph SP (no literals).
  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = each.value.scopes
      content {
        id = (
          local.graph_scopes[resource_access.value].type == "Role"
          ? data.azuread_service_principal.msgraph.app_role_ids[local.graph_scopes[resource_access.value].name]
          : data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[local.graph_scopes[resource_access.value].name]
        )
        type = local.graph_scopes[resource_access.value].type
      }
    }
  }

  # ADDED on apply (live has no owners — named in the PR body): the two
  # company owners, on the app AND its SP.
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

  # FALSE on all four LIVE SPs (export 2026-10-27): the opshub-users/employee
  # gate never shipped, so there is nothing to preserve here.
  app_role_assignment_required = false
  client_id                    = each.value.client_id
  owners                       = [var.owner_operator_object_id, var.second_owner_object_id]
}

# ── Tenant-wide delegated consent for every sign-in app ─────────────────────
#
# Without an AllPrincipals grant every user sees a consent prompt the first time
# (and a tenant without user consent cannot complete the sign-in at all). The
# scopes are the delegated set every sign-in app needs; a grant only takes
# effect for scopes the app requests. The OpsHub Prod grant was made by hand on
# 2026-11-05; the grant id is imported, not recreated.
#
# The id map is built read-only by scripts/owner/identity-env/identity-env.sh
# from live oauth2PermissionGrants (consentType AllPrincipals, resource =
# Microsoft Graph). A key missing from the map plans a CREATE; against a live
# grant that is a duplicate and Entra answers 409 — so the kit must see it.
variable "signin_delegated_grant_ids" {
  type        = map(string)
  default     = {}
  description = "AllPrincipals oauth2PermissionGrant ids already live, keyed as local.signin_delegated_grant_targets (rova_prod, rova_dev, opshub_dev, kb_dev, opshub_prod). Built by scripts/owner/identity-env/identity-env.sh; never committed."

  validation {
    condition     = alltrue([for id in values(var.signin_delegated_grant_ids) : can(regex("^[A-Za-z0-9_=-]+$", id))])
    error_message = "signin_delegated_grant_ids values must be Graph grant ids (opaque, no slashes)."
  }
}

variable "signin_delegated_grant_scopes" {
  type        = map(list(string))
  default     = {}
  description = "Delegated scopes already present in each live AllPrincipals Graph grant, keyed like local.signin_delegated_grant_targets. Built by scripts/owner/identity-env/identity-env.sh from the same read-only oauth2PermissionGrants lookup as the id map; never committed. A listed scope missing from the derived set fails the plan: an apply must never narrow a live grant."

  validation {
    condition = alltrue([
      for scopes in values(var.signin_delegated_grant_scopes) :
      alltrue([for scope in scopes : can(regex("^[A-Za-z0-9._-]+$", scope))])
    ])
    error_message = "signin_delegated_grant_scopes values must be lists of Graph delegated scope names."
  }
}

locals {
  signin_delegated_grant_targets = merge(
    { for k, sp in azuread_service_principal.signin : k => sp.object_id },
    { opshub_prod = azuread_service_principal.opshub_prod.object_id },
  )

  # The kit-built import map. Kept as a local so the variable is a declared
  # dependency of the configuration (the import block consumes the local).
  signin_delegated_grant_imports = var.signin_delegated_grant_ids

  # A grant can only carry scopes the app REQUESTS; setting a fixed five-scope
  # list would strip KB's Files.*/Sites.* delegated scopes on an apply. Derive
  # the delegated scope names from local.signin_apps (User.Invite.All is an
  # application Role, not a delegated scope) and give the prod app the same set
  # as its dev sibling.
  signin_delegated_scopes = merge(
    {
      for k, app in local.signin_apps : k => [
        for scope in app.scopes : local.graph_scopes[scope].name
        if local.graph_scopes[scope].type == "Scope"
      ]
    },
    { opshub_prod = ["openid", "profile", "email", "offline_access", "User.Read"] },
  )
}

import {
  for_each = local.signin_delegated_grant_imports
  to       = azuread_service_principal_delegated_permission_grant.signin[each.key]
  id       = "/oauth2PermissionGrants/${each.value}"
}

resource "azuread_service_principal_delegated_permission_grant" "signin" {
  for_each = local.signin_delegated_grant_targets

  service_principal_object_id          = each.value
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = local.signin_delegated_scopes[each.key]

  # An apply REPLACES claim_values with the derived set, so a delegated scope
  # the LIVE grant carries but the app no longer requests would be revoked
  # silently (the KB Dev `email` case, found on the #381 plan). The kit reads
  # each live grant's scope list into signin_delegated_grant_scopes; fail the
  # plan instead of narrowing a live grant.
  lifecycle {
    precondition {
      condition = alltrue([
        for scope in try(var.signin_delegated_grant_scopes[each.key], []) :
        contains(local.signin_delegated_scopes[each.key], scope)
      ])
      error_message = "The live AllPrincipals grant for '${each.key}' carries a delegated scope the app does not request. Add it to that app's delegated scope set in apps.tf (local.signin_apps[*].scopes): an apply would remove it from the live grant."
    }

    # An imported grant with no scope list would make the check above vacuous
    # (an older kit exports the ids only). Both maps come from one lookup, so
    # their key sets must agree.
    precondition {
      condition = (
        !contains(keys(var.signin_delegated_grant_ids), each.key) ||
        contains(keys(var.signin_delegated_grant_scopes), each.key)
      )
      error_message = "signin_delegated_grant_scopes has no entry for '${each.key}' although its live grant is imported. Run the current scripts/owner/identity-env/identity-env.sh; planning with an ids-only environment would skip the no-narrowing check."
    }
  }
}

# Admin -> the existing admin group. The other OpsHub roles stay per-user:
# no role-specific Entra group exists yet (owner decision 2026-11-05: admin
# only now). Adding a group assignment never removes the live user grants.
resource "azuread_app_role_assignment" "opshub_dev_admin" {
  app_role_id         = var.opshub_dev_app_role_ids["admin"]
  principal_object_id = var.platform_admins_object_id
  resource_object_id  = azuread_service_principal.signin["opshub_dev"].object_id
}

output "signin_app_client_ids" {
  description = "Client (application) IDs for the products' MICROSOFT_CLIENT_ID values. Never carries a secret."
  value       = { for k, app in azuread_application.signin : k => app.client_id }
}
