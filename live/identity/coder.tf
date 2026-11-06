# ── Coder: the VLSI workspace platform's sign-in (design §5.2) ───────────────
#
# Owner decision 2026-11-06 ("go VLSI", product-docs projects/vlsi-platform/00_DESIGN.md):
# Coder runs on the company k3s with its OWN Entra OIDC login. No Cloudflare Access in
# front (design §5.2): Access puts a browser redirect in front of every request, and
# `coder` CLI, `coder ssh`, the workspace agents and the websockets under /api/v2 do not
# follow it. Coder is not public at all — live/edge routes coder.qnsc.vn and
# *.coder.qnsc.vn over WARP only (private hostname routes), so Entra is the only door.
#
# THE ACCESS CONTROL is Coder's own allow list:
#   CODER_OIDC_ALLOWED_GROUPS  = the object id of grp-qnsc-vlsi (output grp_vlsi_id)
#   CODER_OIDC_GROUP_FIELD     = groups
# The second one is not optional: in Coder's AGPL code the allow-list check only runs
# when the group field is set AND the list is non-empty (coderd/idpsync/group.go,
# AGPLIDPSync.ParseGroupClaims: `if s.GroupField != "" && len(s.GroupAllowList) > 0`).
# With the field unset, the list is ignored SILENTLY and everyone who can sign in gets
# in. Membership of grp-qnsc-vlsi is managed in Entra (admin center), not here.
#
# The groups claim carries OBJECT IDS, not display names: the tenant has no Entra ID
# P1, so an ApplicationGroup claim is unavailable and SecurityGroup is the only form
# (same as the "QNSC Proxmox" app, proxmox.tf). Entra also caps the claim at 200
# groups and switches to a _claim_names overage above that; the company has far fewer.
#
# Rules carried over from the product sign-in apps (apps.tf):
#   - DELEGATED Graph scopes only; no application role, no app-only token.
#   - the client secret VALUE never touches state: the owner creates it out of band
#     with scripts/rotate-signin-secret.sh (6 months, -expires tag) straight into
#     kv-qnsc-platform, the vault the `platform` ESO store syncs from. Tofu owns shape.
#   - owners: the owner operator + one second company owner. NO CI identity.
#   - single tenant, and the redirect is the deployed host only.

variable "coder_redirect_uris" {
  type        = list(string)
  default     = ["https://coder.qnsc.vn/api/v2/users/oidc/callback"]
  description = "Coder's OIDC redirect URIs. The host is a public product hostname (like rova.qnsc.vn), so the default is committed; override only for a differently-named deployment."

  validation {
    condition     = length(var.coder_redirect_uris) > 0 && alltrue([for u in var.coder_redirect_uris : can(regex("^https://[^/]+/api/v2/users/oidc/callback$", u))])
    error_message = "Every coder_redirect_uris entry must be https://<host>/api/v2/users/oidc/callback — the path Coder registers (coder.com/docs/admin/users/oidc-auth)."
  }
}

resource "azuread_group" "vlsi" {
  display_name     = "grp-qnsc-vlsi"
  description      = "VLSI engineers: the Coder sign-in allow list (CODER_OIDC_ALLOWED_GROUPS). Nothing else uses it."
  security_enabled = true

  lifecycle {
    ignore_changes = [members] # membership is managed in Entra, not in this stack
  }
}

resource "azuread_application" "coder" {
  display_name            = "Coder"
  sign_in_audience        = "AzureADMyOrg"
  group_membership_claims = ["SecurityGroup"]

  web {
    redirect_uris = var.coder_redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  # The groups claim is what the allow list reads; email and preferred_username are
  # Coder's default claim names for the account (CODER_OIDC_EMAIL_FIELD /
  # CODER_OIDC_USERNAME_FIELD then need no override).
  optional_claims {
    id_token {
      name = "groups"
    }
    id_token {
      name = "email"
    }
    id_token {
      name = "preferred_username"
    }
  }

  # offline_access: Coder keeps a refresh token for the deployment's session refresh.
  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = ["openid", "profile", "email", "offline_access"]
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[local.graph_scopes[resource_access.value].name]
        type = "Scope"
      }
    }
  }

  owners = [var.owner_operator_object_id, var.second_owner_object_id]
}

resource "azuread_service_principal" "coder" {
  client_id = azuread_application.coder.client_id
  # FALSE: the door is Coder's allow list, not Entra app assignment. TRUE would need
  # an assignment per user (the tenant has no P1 for group assignment) and would
  # refuse anyone the list already refuses.
  app_role_assignment_required = false
  owners                       = [var.owner_operator_object_id, var.second_owner_object_id]
}

# Admin consent for the delegated scopes, all principals: without it every user meets
# a consent prompt on the first sign-in, and a tenant with user consent disabled
# cannot complete the sign-in at all. Same shape as the product sign-in grants.
resource "azuread_service_principal_delegated_permission_grant" "coder" {
  service_principal_object_id          = azuread_service_principal.coder.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = ["openid", "profile", "email", "offline_access"]
}

output "coder_oidc_client_id" {
  description = "Client (application) id for CODER_OIDC_CLIENT_ID (gitops, platform values). Never carries a secret."
  value       = azuread_application.coder.client_id
}

output "coder_oidc_issuer_url" {
  description = "Issuer URL for CODER_OIDC_ISSUER_URL (the v2.0 endpoint, which is what emits the groups claim)."
  value       = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"
}

output "coder_signin_app_object_id" {
  description = "Object id of the Coder registration, for scripts/rotate-signin-secret.sh (the credential is created out of band, never by tofu)."
  value       = azuread_application.coder.id
}

output "grp_vlsi_id" {
  description = "Object id of grp-qnsc-vlsi, for CODER_OIDC_ALLOWED_GROUPS (and the gitops value the ESO Secret supplies)."
  value       = azuread_group.vlsi.object_id
}
