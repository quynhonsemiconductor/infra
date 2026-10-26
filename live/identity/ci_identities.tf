# ── The two CI identities (§7.4) ────────────────────────────────────────────
#
# "QNSC CI Infra" applies the OTHER stacks; "QNSC CI Infra Read" plans, drifts
# and checks expiry — including THIS stack. Both are workload identities:
# GitHub OIDC in, no client secret EVER (they only ever EXIST here — tofu
# prints their client IDs, which are public identifiers, not secrets).
#
# THIS stack (live/identity) is applied ONLY by the owner, locally, with their
# own `az login`. CI never applies it: an identity that can apply live/identity
# could grant itself anything in the tenant, so CI "QNSC CI Infra" is given NO
# Entra directory role and NO right to assign Azure roles.
#
#   Apply  — federated credential on the infra repo environment `production`
#            (the required-reviewer gate; the GitHub environment is named
#            `production`, so the OIDC subject is environment:production),
#            because only a merged, reviewed run may change anything.
#   Read   — federated credentials for pull_request (every PR plan) and
#            ref:refs/heads/main (the scheduled drift + expiry jobs).
#
# Least privilege, and why each role is on the list:
#   Apply (Azure RBAC): Contributor on the ONE platform subscription (the
#     other stacks create/update resources) + Storage Blob Data Contributor
#     on stqnsctfstate (the state data plane). Deliberately NOT granted:
#     User Access Administrator / RBAC Administrator (no other stack assigns
#     Azure roles; if one ever must assign DATA roles, add "Role Based Access
#     Control Administrator" with a condition limiting the assignable roles —
#     never User Access Administrator) and any Entra directory role
#     (Privileged Role / Application / User Administrator).
#   Read — Directory Readers (Entra: plan can read apps, groups, users and
#     role assignments), Reader (subscription), Storage Blob Data Reader
#     (stqnsctfstate, state files are blobs) and Key Vault Reader (metadata
#     only — it must never read a value, §7).

locals {
  github_oidc_issuer = "https://token.actions.githubusercontent.com"
  infra_subject_base = "repo:quynhonsemiconductor/infra"
}

resource "azuread_application" "ci_infra_apply" {
  display_name     = "QNSC CI Infra"
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "ci_infra_apply" {
  client_id = azuread_application.ci_infra_apply.client_id
}

resource "azuread_application_federated_identity_credential" "ci_infra_apply" {
  application_id = azuread_application.ci_infra_apply.id
  display_name   = "infra-environment-production"
  description    = "infra repo environment production (required reviewer gate) — apply runs"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.github_oidc_issuer
  subject        = "${local.infra_subject_base}:environment:production"
}

resource "azuread_application" "ci_infra_read" {
  display_name     = "QNSC CI Infra Read"
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "ci_infra_read" {
  client_id = azuread_application.ci_infra_read.client_id
}

resource "azuread_application_federated_identity_credential" "ci_infra_read_pr" {
  application_id = azuread_application.ci_infra_read.id
  display_name   = "infra-pull-request"
  description    = "infra PR plans"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.github_oidc_issuer
  subject        = "${local.infra_subject_base}:pull_request"
}

resource "azuread_application_federated_identity_credential" "ci_infra_read_main" {
  application_id = azuread_application.ci_infra_read.id
  display_name   = "infra-main-schedule"
  description    = "scheduled drift + expiry jobs on main"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.github_oidc_issuer
  subject        = "${local.infra_subject_base}:ref:refs/heads/main"
}

# Azure RBAC — apply: Contributor on the subscription, Storage Blob Data
# Contributor on the state account. No role-assignment rights (see header).
resource "azurerm_role_assignment" "ci_apply_contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.ci_infra_apply.object_id
}

resource "azurerm_role_assignment" "ci_apply_state_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.ci_infra_apply.object_id
}

# Azure RBAC — read: Reader (subscription), state blobs + vault metadata.
resource "azurerm_role_assignment" "ci_read_reader" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.ci_infra_read.object_id
}

resource "azurerm_role_assignment" "ci_read_state_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azuread_service_principal.ci_infra_read.object_id
}

resource "azurerm_role_assignment" "ci_read_kv_metadata" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Key Vault Reader"
  principal_id         = azuread_service_principal.ci_infra_read.object_id
}

# Entra directory role — READ identity only: Directory Readers (the plan reads
# applications, groups, users and directory role assignments). The apply
# identity holds NO directory role. `azuread_directory_role` activates the
# role in the tenant if it is not yet (idempotent).
resource "azuread_directory_role" "directory_readers" {
  display_name = "Directory Readers"
}

resource "azuread_directory_role_assignment" "ci_read_directory_readers" {
  role_id             = azuread_directory_role.directory_readers.template_id
  principal_object_id = azuread_service_principal.ci_infra_read.object_id
}

# Client IDs are public identifiers — safe to print; the workflows need them
# (repo variables set after the first apply, see README.md).
output "ci_infra_apply_client_id" {
  description = "QNSC CI Infra client ID — repo variable for the other stacks' apply workflows."
  value       = azuread_application.ci_infra_apply.client_id
}

output "ci_infra_read_client_id" {
  description = "QNSC CI Infra Read client ID — repo variable for plan/drift workflows."
  value       = azuread_application.ci_infra_read.client_id
}
