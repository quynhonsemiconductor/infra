# ── "QNSC k3s": kubectl authentication against the cluster (owner plan item, 2026-11-06) ──────
#
# Admins and developers stop sharing long-lived admin kubeconfig files: kubelogin
# (`kubectl oidc-login`) signs them in with Entra, the k3s API server verifies the ID token as an
# OIDC provider, and RBAC maps the Entra groups to cluster roles. The admin kubeconfig stays as
# break-glass, offline, in 1Password — never on a laptop.
#
# This app is a PUBLIC CLIENT: kubectl runs on a laptop, so there is no place to keep a secret and
# the authorization-code flow with PKCE is the right one. No client secret exists, nothing to rotate.
#
# The API server reads the user's groups from the `groups` claim, so this app uses
# SecurityGroup membership claims (object ids) — the same reason as the Coder app: no Entra ID P1,
# so ApplicationGroup/display names are unavailable.
#
# Redirect URIs are kubelogin's own defaults (http://localhost:<port>): 8000, and 18000 which it
# falls back to when 8000 is taken. Entra treats http://localhost as a native redirect and allows
# it on a public client.
#
# The group ids and the client id reach the cluster through the git-ignored Ansible inventory
# (k3s_server_entra_* in the k3s_server role), never through this file.

resource "azuread_application" "k3s" {
  display_name            = "QNSC k3s"
  sign_in_audience        = "AzureADMyOrg"
  group_membership_claims = ["SecurityGroup"]

  web {
    # No web redirect: kubectl is the client, and it is native. Keeping `web` empty also matches
    # what Entra shows for a public client.
    redirect_uris = []
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  # Public client (module presence = allowPublicClient in Entra; azuread 3.10 exposes only the
  # redirect list here). No secret exists, so kubelogin's authcode flow with PKCE is the primary
  # path; device code (`--grant-type=device-code`) is the fallback on a machine without a browser.
  # Redirect URIs are kubelogin's own defaults — port 8000, and 18000 when 8000 is taken.
  public_client {
    redirect_uris = [
      "http://localhost:8000",
      "http://localhost:18000",
    ]
  }

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

  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = ["openid", "profile", "email"]
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[local.graph_scopes[resource_access.value].name]
        type = "Scope"
      }
    }
  }

  owners = [var.owner_operator_object_id, var.second_owner_object_id]
}

resource "azuread_service_principal" "k3s" {
  client_id                    = azuread_application.k3s.client_id
  app_role_assignment_required = false
  owners                       = [var.owner_operator_object_id, var.second_owner_object_id]
}

# Admin consent for the delegated scopes, all principals: a laptop cannot show a consent prompt to
# someone whose first sign-in is `kubectl`, and a tenant with user consent disabled cannot complete
# the flow at all.
resource "azuread_service_principal_delegated_permission_grant" "k3s" {
  service_principal_object_id          = azuread_service_principal.k3s.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = ["openid", "profile", "email"]
}

output "k3s_oidc_client_id" {
  description = "Client id for the k3s API server (--oidc-client-id) and kubelogin (--client-id). Public identifier."
  value       = azuread_application.k3s.client_id
}

output "k3s_oidc_issuer_url" {
  description = "Issuer URL for --oidc-issuer-url (the v2.0 endpoint, the one that emits the groups claim)."
  value       = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"
}

output "k3s_oidc_app_object_id" {
  description = "Object id of the registration (owner reference for the portal)."
  value       = azuread_application.k3s.id
}
