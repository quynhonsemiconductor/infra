# ── Prod identity: OpsHub Prod + OpsHub Prod Service (§7.2, §7.3) ──────────
#
# The dev pair is in apps.tf / mail.tf, adopted from the live registrations.
# The PROD pair does not exist yet, so it is CREATED here (no import blocks):
# the app-registration shape belongs to OpenTofu, exactly like the dev pair's.
#
# "OpsHub Prod" — the sign-in app, DELEGATED Graph scopes only (same set the
# dev app holds), one redirect: the deployed prod callback. NO loopback: prod
# sign-in only ever happens on https://opshub.qnsc.vn. Its client SECRET is
# never modelled here (values never touch state): the owner creates it with
# scripts/rotate-signin-secret.sh (--append, +6 months) straight into
# kv-qnsc-prod/opshub-prod-entra-client-secret.
#
# The seven app roles are the same roles opshub's RBAC uses (`admin`,
# `it-admin`, …): a new registration has none, and without them nobody can be
# granted anything inside opshub. Values match local.opshub_app_roles; the
# role ids are provider-generated (computed), not hand-written.
#
# "OpsHub Prod Service" — the worker's Graph app: CERTIFICATE ONLY, the same
# three application roles as the dev service app (Intune-managed devices,
# security events, users). Never Mail.Send in Entra: prod mail is Exchange
# RBAC for Applications, scoped to noreply-opshub@qnsc.vn, and stays an
# owner-run PowerShell step (README "Prod identity: OpsHub"). The certificate
# is created from the PUBLIC half the owner passes in
# TF_VAR_opshub_prod_service_certificate; the combined PEM (private key
# (PKCS#8) FIRST, then the certificate — the order the gitops consumer
# values/opshub/prod.secrets.yaml reads) is written by the owner to
# kv-qnsc-prod/opshub-prod-graph-cert and read by the worker through ESO —
# never through Terraform.
#
# The service pair exists only once that certificate is supplied: the whole
# block is gated on the variable, so a plan without it adds nothing half-made.
# The expected plan is in the README.

resource "azuread_application" "opshub_prod" {
  display_name     = "OpsHub Prod"
  sign_in_audience = "AzureADMyOrg"
  # Same as the dev app: no group-membership claims (RBAC is the app roles;
  # grp-qnsc-staff gates the HOST at Cloudflare Access, not the token).
  group_membership_claims = ["None"]
  identifier_uris         = []

  web {
    redirect_uris = ["https://opshub.qnsc.vn/api/auth/callback/microsoft"]
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  # Same optional id-token claims the dev app carries (email + acct).
  optional_claims {
    id_token {
      name = "email"
    }
    id_token {
      name = "acct"
    }
  }

  # Delegated scopes only — never an application Role on a sign-in app.
  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = ["openid", "profile", "email", "offline_access", "User_Read"]
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[local.graph_scopes[resource_access.value].name]
        type = "Scope"
      }
    }
  }

  owners = [var.owner_operator_object_id, var.second_owner_object_id]

  # A 9-add partial apply (sign-in app only, service app skipped) must be
  # impossible: the prod pair is applied together or not at all. The owner
  # supplies the PUBLIC certificate in the same plan.
  lifecycle {
    precondition {
      condition     = var.opshub_prod_service_certificate != null
      error_message = "set TF_VAR_opshub_prod_service_certificate: expected plan is 12 add"
    }
  }
}

locals {
  # Role ids are GUIDs that Entra keeps for the life of the role — public
  # identifiers (the dev roles' ids live in TF_VAR_opshub_dev_app_role_ids for
  # the same reason). They are DERIVED, not pasted: a name-based UUID (RFC
  # 4122 v5) from the role key, so the same role gets the same id on every
  # plan and no literal GUID enters the tree. Display names, descriptions and
  # member types come from the shared map so dev and prod cannot drift apart.
  opshub_prod_app_role_ids = {
    for k in keys(local.opshub_app_roles) : k => uuidv5("dns", "qnsc.vn/identity/opshub-prod/${k}")
  }
}

resource "azuread_application_app_role" "opshub_prod" {
  for_each = local.opshub_prod_app_role_ids

  application_id       = azuread_application.opshub_prod.id
  role_id              = each.value
  allowed_member_types = local.opshub_app_roles[each.key].allowed_member_types
  description          = local.opshub_app_roles[each.key].description
  display_name         = local.opshub_app_roles[each.key].display_name
  value                = each.key
}

resource "azuread_service_principal" "opshub_prod" {
  app_role_assignment_required = false
  client_id                    = azuread_application.opshub_prod.client_id
  owners                       = [var.owner_operator_object_id, var.second_owner_object_id]
}

variable "opshub_prod_service_certificate" {
  type        = string
  default     = null
  description = "PUBLIC certificate (PEM) for the new 'OpsHub Prod Service' app, generated locally by the owner (RSA 2048, <= 24 months) together with its private key. Passed through TF_VAR_opshub_prod_service_certificate; the combined PEM goes to kv-qnsc-prod/opshub-prod-graph-cert (owner, stdin). Never a private key. Null = the prod service app is not created yet."

  validation {
    condition = var.opshub_prod_service_certificate == null || (
      can(regex("-----BEGIN CERTIFICATE-----", var.opshub_prod_service_certificate)) &&
      !can(regex("PRIVATE KEY", var.opshub_prod_service_certificate))
    )
    error_message = "opshub_prod_service_certificate must be a PEM PUBLIC certificate (BEGIN CERTIFICATE); a private key is never accepted."
  }
}

resource "azuread_application" "opshub_prod_service" {
  count = var.opshub_prod_service_certificate == null ? 0 : 1

  display_name     = "OpsHub Prod Service"
  notes            = "github.com/quynhonsemiconductor/opshub"
  sign_in_audience = "AzureADMyOrg"

  # Exactly the dev service app's three application roles; NEVER Mail.Send
  # (§7.3). Mail is Exchange RBAC for Applications, owner-run.
  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id
    dynamic "resource_access" {
      for_each = ["DeviceManagementManagedDevices.Read.All", "SecurityEvents.Read.All", "User.Read.All"]
      content {
        id   = data.azuread_service_principal.msgraph.app_role_ids[resource_access.value]
        type = "Role"
      }
    }
  }
}

resource "azuread_application_certificate" "opshub_prod_service" {
  count = var.opshub_prod_service_certificate == null ? 0 : 1

  application_id = azuread_application.opshub_prod_service[0].id
  type           = "AsymmetricX509Cert"
  value          = var.opshub_prod_service_certificate
  encoding       = "pem"

  # Rotation issues the NEW credential before the old one is removed; the
  # worker's PEM in the vault is swapped right after apply (README).
  lifecycle {
    create_before_destroy = true
  }
}

resource "azuread_service_principal" "opshub_prod_service" {
  count = var.opshub_prod_service_certificate == null ? 0 : 1

  client_id = azuread_application.opshub_prod_service[0].client_id
}

output "opshub_prod_client_ids" {
  description = "Client (application) ids for gitops values/opshub/prod.yaml: signin = <OPSHUB_PROD_ENTRA_CLIENT_ID>, service = <OPSHUB_PROD_SERVICE_APP_ID>. Public identifiers, never a secret."
  value = {
    signin  = azuread_application.opshub_prod.client_id
    service = one(azuread_application.opshub_prod_service[*].client_id)
  }
}

output "opshub_prod_object_ids" {
  description = "Object ids the owner needs for the follow-up steps: signin_app is the argument of scripts/rotate-signin-secret.sh, service_app is the service app-registration object id, the two *_sp ids are the enterprise-application object ids (Exchange New-ServicePrincipal takes the app id AND the SP object id). Not secrets."
  value = {
    signin_app       = azuread_application.opshub_prod.id
    signin_sp        = azuread_service_principal.opshub_prod.object_id
    service_app      = one(azuread_application.opshub_prod_service[*].id)
    service_sp       = one(azuread_service_principal.opshub_prod_service[*].object_id)
    signin_app_roles = { for k, r in azuread_application_app_role.opshub_prod : k => r.role_id }
  }
}
