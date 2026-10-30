# ── Proxmox login through Entra (OpenID Connect) ────────────────────────────
#
# One single-tenant, web-platform app registration "QNSC Proxmox" that backs
# the Proxmox VE OpenID realm. The Proxmox side (realm, group, ACL) is the
# platform runbook's job, not this stack's.
#
# Rules:
#   - the redirect URIs are the Proxmox admin-door origin: an admin-door
#     hostname is Tier 1 in a public repo, so it arrives by variable
#     (TF_VAR_proxmox_redirect_uris), never committed.
#   - groups claim = ApplicationGroup: the ID token carries ONLY the groups
#     assigned to this enterprise app that the user belongs to, as display
#     names (`cloud_displayname`, valid only with ApplicationGroup and only
#     for cloud-only groups). Proxmox appends "-<realm>" to a claim group
#     name, so grp-qnsc-platform-admins becomes the Proxmox group
#     grp-qnsc-platform-admins-entra (runbook server-setup §3.2).
#   - sign-in is restricted: app_role_assignment_required = true and ONE
#     group assigned (grp-qnsc-platform-admins, the same group Cloudflare
#     Access lets in). Anyone else is refused by Entra before Proxmox sees a
#     token.
#   - the client-secret VALUE never touches state (same rule as the sign-in
#     apps, main.tf / scripts/rotate-signin-secret.sh): the owner creates it
#     out of band into kv-qnsc-admin (README "Proxmox login"). Tofu owns shape
#     only; tests/static.sh fails any password credential here.
#   - owners: the same two company owners as the sign-in apps. NO CI identity.

variable "proxmox_redirect_uris" {
  type        = list(string)
  description = "Redirect URIs of the Proxmox realm: the Proxmox origin with and without a trailing slash (https://<host> and https://<host>/). TF_VAR_proxmox_redirect_uris (JSON list), never committed (admin-door hostname)."

  validation {
    condition     = length(var.proxmox_redirect_uris) > 0 && alltrue([for u in var.proxmox_redirect_uris : startswith(u, "https://")])
    error_message = "proxmox_redirect_uris must be a non-empty list of https:// URIs."
  }
}

resource "azuread_application" "proxmox" {
  display_name            = "QNSC Proxmox"
  sign_in_audience        = "AzureADMyOrg"
  group_membership_claims = ["ApplicationGroup"]

  web {
    redirect_uris = var.proxmox_redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  optional_claims {
    id_token {
      name                  = "groups"
      additional_properties = ["cloud_displayname"]
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

# Assignment of the group to the enterprise app. The all-zero id is the
# well-known "default access" role of an app that defines no app roles.
resource "azuread_app_role_assignment" "proxmox_platform_admins" {
  app_role_id         = "00000000-0000-0000-0000-000000000000"
  principal_object_id = var.platform_admins_object_id
  resource_object_id  = azuread_service_principal.proxmox.object_id
}

output "proxmox_oidc_client_id" {
  description = "Client (application) ID for the Proxmox realm's --client-id. Never carries a secret."
  value       = azuread_application.proxmox.client_id
}

output "proxmox_oidc_issuer_url" {
  description = "Issuer URL for the Proxmox realm's --issuer-url (v2.0 endpoint)."
  value       = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"
}
