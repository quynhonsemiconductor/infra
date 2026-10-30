# ── Proxmox login through Entra (OpenID Connect) ────────────────────────────
#
# One single-tenant, web-platform app registration "QNSC Proxmox" that backs
# the Proxmox VE OpenID realm. The Proxmox side (realm, group, ACL) is the
# platform runbook's job, not this stack's.
#
# Rules:
#   - the redirect URI is the Proxmox admin-door origin: an admin-door
#     hostname is Tier 1 in a public repo, so it arrives by variable
#     (TF_VAR_proxmox_redirect_uris), never committed. azuread 3.10 forces a
#     trailing slash on a path-less URI, so only https://<host>/ is
#     registered; pve-manager sends location.origin (no slash) and Entra
#     normalises the root (Microsoft Learn, reply URL restrictions).
#   - groups claim = SecurityGroup: the ID token carries the user's security
#     group OBJECT IDS (the tenant has no Entra ID P1, so ApplicationGroup /
#     group-based assignment / display names are unavailable). Proxmox appends
#     "-<realm>" to a claim group name, so grp-qnsc-platform-admins becomes
#     the Proxmox group <its-object-id>-entra (runbook server-setup §3.2.1).
#   - sign-in is restricted: app_role_assignment_required = true and the admin
#     USERS are assigned DIRECTLY (group assignment needs P1). Anyone not
#     assigned is refused by Entra before Proxmox sees a token. Adding or
#     removing an admin = edit proxmox_admin_object_ids (and the Entra group,
#     which Cloudflare Access and the Proxmox ACL key on).
#   - the client-secret VALUE never touches state (same rule as the sign-in
#     apps, main.tf / scripts/rotate-signin-secret.sh): the owner creates it
#     out of band into kv-qnsc-admin (README "Proxmox login"). Tofu owns shape
#     only; tests/static.sh fails any password credential here.
#   - owners: the same two company owners as the sign-in apps. NO CI identity.

variable "proxmox_redirect_uris" {
  type        = list(string)
  description = "Redirect URI of the Proxmox realm: https://<host>/ (trailing slash REQUIRED by azuread 3.10). TF_VAR_proxmox_redirect_uris (JSON list), never committed (admin-door hostname)."

  validation {
    condition     = length(var.proxmox_redirect_uris) > 0 && alltrue([for u in var.proxmox_redirect_uris : can(regex("^https://[^/]+/$", u))])
    error_message = "proxmox_redirect_uris must be a non-empty list of https://<host>/ URIs (origin with a trailing slash, no path)."
  }
}

variable "proxmox_admin_object_ids" {
  type        = set(string)
  description = "Object ids of the USERS assigned to the Proxmox app (no Entra ID P1: group assignment is unavailable). Keep in step with grp-qnsc-platform-admins. TF_VAR_proxmox_admin_object_ids (JSON list), never committed."

  validation {
    condition = length(var.proxmox_admin_object_ids) > 0 && alltrue([
      for id in var.proxmox_admin_object_ids :
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id))
    ])
    error_message = "proxmox_admin_object_ids must be a non-empty set of user object ids (GUIDs)."
  }
}

resource "azuread_application" "proxmox" {
  display_name            = "QNSC Proxmox"
  sign_in_audience        = "AzureADMyOrg"
  group_membership_claims = ["SecurityGroup"]

  web {
    redirect_uris = var.proxmox_redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  optional_claims {
    id_token {
      name = "groups"
    }
    # Proxmox derives the username from `email` (runbook): managed users get
    # it only when requested here or via the email scope.
    id_token {
      name = "email"
    }
  }

  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = ["openid", "profile", "email"]
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[resource_access.value]
        type = "Scope"
      }
    }
  }

  owners = [var.owner_operator_object_id, var.second_owner_object_id]
}

resource "azuread_service_principal" "proxmox" {
  client_id                    = azuread_application.proxmox.client_id
  app_role_assignment_required = true
  owners                       = [var.owner_operator_object_id, var.second_owner_object_id]
}

# Direct USER assignment (no P1 for groups). The all-zero id is the
# well-known "default access" role of an app that defines no app roles.
resource "azuread_app_role_assignment" "proxmox_admins" {
  for_each = var.proxmox_admin_object_ids

  app_role_id         = "00000000-0000-0000-0000-000000000000"
  principal_object_id = each.value
  resource_object_id  = azuread_service_principal.proxmox.object_id
}

# Admin consent for the delegated sign-in scopes, all principals: an app that
# requires assignment cannot show users a consent prompt.
resource "azuread_service_principal_delegated_permission_grant" "proxmox" {
  service_principal_object_id          = azuread_service_principal.proxmox.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = ["openid", "profile", "email"]
}

output "proxmox_oidc_client_id" {
  description = "Client (application) ID for the Proxmox realm's --client-id. Never carries a secret."
  value       = azuread_application.proxmox.client_id
}

output "proxmox_oidc_issuer_url" {
  description = "Issuer URL for the Proxmox realm's --issuer-url (v2.0 endpoint)."
  value       = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"
}
