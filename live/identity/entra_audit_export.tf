# ── Entra directory AUDIT logs: 365-day export (hardening decision 8) ───────
#
# Owner decision 2026-11-04 §8: Entra ID P1 is not bought, so the tenant keeps
# Microsoft's native retention (7 days for audit AND sign-in logs). This file
# exports what the FREE tier actually allows, and the runbook
# docs/runbooks/entra-activity-logs.md records the sign-in gap and its
# compensation.
#
# What is free, verified 2026-11-06 against the tenant and the docs:
#   * directory AUDIT logs: readable on Microsoft Entra ID Free. Proof on this
#     tenant: `az rest GET /v1.0/auditLogs/directoryAudits?$top=1` returns 200
#     with a fresh record.
#   * SIGN-IN logs: NOT readable without P1/P2. Proof on this tenant:
#     `az rest GET /v1.0/auditLogs/signIns` returns 403
#     "Authentication_RequestFromNonPremiumTenantOrB2CTenant".
#   * Diagnostic settings: the docs' licence table lists audit logs as included
#     in Free, but the azuread provider has NO diagnostic-setting resource (only
#     an ARM deployment against microsoft.aadiam could create one), and the
#     Graph pull is provable today with a single read call. One mechanism, one
#     owner, no new deployment scope.
#
# Shape: a dedicated, secret-less app "QNSC Entra Audit Export" (GitHub OIDC,
# subject ref:refs/heads/main only) holds Graph application permission
# AuditLog.Read.All and Storage Blob Data Contributor on the audit account. A
# nightly workflow (.github/workflows/entra-audit-export.yml) appends one gzip
# JSONL per run to container `entra-audit`; the container is WORM for 365 days
# and the lifecycle rule below deletes at the same age.
#
# This stack is applied ONLY by the owner with scripts/owner/identity-env/
# identity-env.sh (see live/identity/README.md). CI plans nothing here.

locals {
  entra_audit_container = "entra-audit"
}

# Gate, not a comment. The policy below is locked on creation and can never be
# weakened; this variable must be set explicitly for the apply that creates it.
# It has no default, is not built by the owner kit, and is never committed.
variable "confirm_worm_irreversible" {
  type        = bool
  default     = false
  description = "Set TF_VAR_confirm_worm_irreversible=true ONLY after reading the IRREVERSIBLE note in live/identity/entra_audit_export.tf and agreeing with the owner. The locked WORM policy on the entra-audit container cannot be removed or shortened afterwards. Enforced by a precondition on the policy, so unrelated applies are not blocked once it exists."
}

# The container the export workflow writes into. Private; no SAS is issued.
resource "azurerm_storage_container" "entra_audit" {
  # checkov:skip=CKV2_AZURE_21:the account's own diagnostic destination is Azure Monitor; blob read logging into the same account would loop
  name                  = local.entra_audit_container
  storage_account_id    = azurerm_storage_account.kv_audit.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true # the audit trail outlives any stack rewrite
  }
}

# Locked, 365-day WORM. Block-blob uploads are how the workflow writes: a NEW
# blob is always allowed, an EXISTING one cannot be changed or deleted until its
# immutability expires. Protected append writes are therefore off (nothing
# appends), unlike the Key Vault container next door, which Azure Monitor writes
# as append blobs.
#
# IRREVERSIBLE: `locked = true` means this policy can never be weakened or
# removed — not by OpenTofu, not by the portal, not by a subscription owner.
# Retention may only be raised. Before the first apply, the owner confirms that
# destroying the identity stack must NOT destroy this trail (prevent_destroy
# above makes the stack fail rather than delete it).
resource "azurerm_storage_container_immutability_policy" "entra_audit" {
  storage_container_resource_manager_id = azurerm_storage_container.entra_audit.id
  immutability_period_in_days           = 365
  protected_append_writes_enabled       = false
  locked                                = true

  lifecycle {
    # The real gate: the plan/apply stops here until the owner has explicitly
    # confirmed the irreversible policy (variable above).
    precondition {
      condition     = var.confirm_worm_irreversible
      error_message = "Refusing to create a LOCKED 365-day WORM policy without confirmation. Read the IRREVERSIBLE note at the top of the entra-audit policy and set TF_VAR_confirm_worm_irreversible=true for the apply that creates it."
    }
  }
}

# The export identity: no client secret, ever. Graph application permission
# AuditLog.Read.All is resolved from the msgraph SP data source (apps.tf), not
# from a literal UUID; the grant below is the admin consent.
resource "azuread_application" "entra_audit_export" {
  display_name     = "QNSC Entra Audit Export"
  sign_in_audience = "AzureADMyOrg"
  notes            = "Nightly directoryAudits export to stqnsckvaudit/entra-audit (infra live/identity/entra_audit_export.tf). Secret-less: GitHub OIDC, subject ref:refs/heads/main."

  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id # Microsoft Graph, from the data source (apps.tf)

    resource_access {
      id   = data.azuread_service_principal.msgraph.app_role_ids["AuditLog.Read.All"]
      type = "Role" # application permission: runs with no signed-in user
    }
  }
}

resource "azuread_service_principal" "entra_audit_export" {
  client_id = azuread_application.entra_audit_export.client_id
}

# Same immutable subject form as the CI identities (ci_identities.tf): schedule
# and dispatch runs on main only. A PR never gets this token.
resource "azuread_application_federated_identity_credential" "entra_audit_export_main" {
  # checkov:skip=CKV_AZURE_249:the subject is the immutable numeric form (repo:quynhonsemiconductor@297362956/infra@1282170347) pinned to ref:refs/heads/main through local.infra_subject_base; a literal here would drift from the two CI identities.
  application_id = azuread_application.entra_audit_export.id
  display_name   = "infra-entra-audit-export-main"
  description    = "nightly Entra audit export, schedules and manual dispatch on main"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.github_oidc_issuer
  subject        = "${local.infra_subject_base}:ref:refs/heads/main"
}

resource "azuread_app_role_assignment" "entra_audit_export_graph" {
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids["AuditLog.Read.All"]
  principal_object_id = azuread_service_principal.entra_audit_export.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Write access is scoped to the `entra-audit` CONTAINER, not the account: the
# same account holds the Key Vault trail, which this identity must never be able
# to write to. Containers support role assignments at container scope.
resource "azurerm_role_assignment" "entra_audit_export_blob" {
  scope                = azurerm_storage_container.entra_audit.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.entra_audit_export.object_id
}

output "entra_audit_export_client_id" {
  description = "Client id of the Entra audit export app (public identifier). Set it as repo VARIABLE AZURE_CLIENT_ID_ENTRA_AUDIT so .github/workflows/entra-audit-export.yml can log in."
  value       = azuread_application.entra_audit_export.client_id
}
