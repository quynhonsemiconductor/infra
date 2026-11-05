# ── Prod identity: KB Prod + KB Prod Service (§7.2, §7.3) ──────────────────
#
# The dev pair is in apps.tf / mail.tf (adopted from the live registrations).
# The PROD pair does not exist, so it is CREATED here (no import blocks).
#
# "KB Prod" — the sign-in app, the dev scope set (openid, profile, email,
# offline_access, User.Read, Files.Read, Files.Read.All, Sites.Read.All), no
# optional id-token claims and NO app roles (the dev registration has none).
# Its TWO redirect URIs are the decided prod host kb.qnsc.vn, the same two
# paths the dev app uses; no loopback (prod sign-in happens on the deployed
# host only). The client secret is never modelled here: the owner creates it
# with scripts/rotate-signin-secret.sh (+6 months) into
# kv-qnsc-prod/kb-prod-microsoft-client-secret (kb names its secrets after the
# env var; values/kb/prod.secrets.yaml).
#
# "KB Prod Service" — certificate only, the same EMPTY Graph permission set as
# the dev service app (kb's mail path is Exchange RBAC for Applications, never
# Mail.Send in Entra). Created only when the PUBLIC certificate is supplied;
# the sign-in app's precondition makes a partial (credential-less) apply
# impossible.
#
# The tenant-wide delegated consent for "KB Prod" is the shared
# azuread_service_principal_delegated_permission_grant.signin["kb_prod"] in
# apps.tf (SAME resource as every other sign-in app, with the #383
# no-narrowing preconditions); the app is wired into
# local.signin_delegated_grant_targets / local.signin_delegated_scopes there.
#
# Carries the same owners pattern as the other prod apps (operator + second
# owner) — the follow-up to replace personal app owners is infra#339.

variable "kb_prod_service_certificate" {
  type        = string
  default     = null
  description = "PUBLIC certificate (PEM) for the new 'KB Prod Service' app, generated locally by the owner together with its private key. Passed through TF_VAR_kb_prod_service_certificate; the combined PEM (private key (PKCS#8) FIRST, then the certificate) goes to kv-qnsc-prod/kb-prod-graph-cert (owner, stdin). Never a private key. Null = the prod service app is not created yet."

  validation {
    condition = var.kb_prod_service_certificate == null || (
      can(regex("-----BEGIN CERTIFICATE-----", var.kb_prod_service_certificate)) &&
      !can(regex("PRIVATE KEY", var.kb_prod_service_certificate))
    )
    error_message = "kb_prod_service_certificate must be a PEM PUBLIC certificate (BEGIN CERTIFICATE); a private key is never accepted."
  }
}

resource "azuread_application" "kb_prod" {
  display_name     = "KB Prod"
  sign_in_audience = "AzureADMyOrg"
  identifier_uris  = []

  web {
    redirect_uris = [
      "https://kb.qnsc.vn/api/v1/auth/entra/callback",
      "https://kb.qnsc.vn/api/v1/connectors/oauth/callback",
    ]
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  # The dev app's delegated scopes (the live KB Dev grant carries `email` too,
  # which the app requests as of #383); no optional claims (matching the dev
  # registration exactly).
  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = ["openid", "profile", "email", "offline_access", "User_Read", "Files_Read", "Files_Read_All", "Sites_Read_All"]
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[local.graph_scopes[resource_access.value].name]
        type = "Scope"
      }
    }
  }

  owners = [var.owner_operator_object_id, var.second_owner_object_id]

  lifecycle {
    precondition {
      condition     = var.kb_prod_service_certificate != null
      error_message = "set TF_VAR_kb_prod_service_certificate before applying the KB prod pair"
    }
  }
}

resource "azuread_service_principal" "kb_prod" {
  app_role_assignment_required = false
  client_id                    = azuread_application.kb_prod.client_id
  owners                       = [var.owner_operator_object_id, var.second_owner_object_id]
}

resource "azuread_application" "kb_prod_service" {
  count = var.kb_prod_service_certificate == null ? 0 : 1

  display_name     = "KB Prod Service"
  notes            = "github.com/quynhonsemiconductor/qnsc-kb-backend"
  sign_in_audience = "AzureADMyOrg"
  # NO required_resource_access: the dev service app holds no Graph
  # permission, and mail is Exchange RBAC (owner PowerShell), never Mail.Send
  # in Entra.
}

resource "azuread_application_certificate" "kb_prod_service" {
  count = var.kb_prod_service_certificate == null ? 0 : 1

  application_id = azuread_application.kb_prod_service[0].id
  type           = "AsymmetricX509Cert"
  value          = var.kb_prod_service_certificate
  encoding       = "pem"

  lifecycle {
    create_before_destroy = true
  }
}

resource "azuread_service_principal" "kb_prod_service" {
  count = var.kb_prod_service_certificate == null ? 0 : 1

  client_id = azuread_application.kb_prod_service[0].client_id
}

output "kb_prod_client_ids" {
  description = "Client (application) ids for the gitops kb prod values: signin = the sign-in app client id, service = the service app client id. Public identifiers."
  value = {
    signin  = azuread_application.kb_prod.client_id
    service = one(azuread_application.kb_prod_service[*].client_id)
  }
}

output "kb_prod_object_ids" {
  description = "Object ids for the owner's follow-up steps: signin_app for scripts/rotate-signin-secret.sh, service_app/service_sp for the Exchange PowerShell. Not secrets."
  value = {
    signin_app  = azuread_application.kb_prod.id
    signin_sp   = azuread_service_principal.kb_prod.object_id
    service_app = one(azuread_application.kb_prod_service[*].id)
    service_sp  = one(azuread_service_principal.kb_prod_service[*].object_id)
  }
}
