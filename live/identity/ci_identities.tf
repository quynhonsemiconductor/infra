# ── The two CI identities (§7.4) ────────────────────────────────────────────
#
# "QNSC CI Infra" applies; "QNSC CI Infra Read" plans, drifts and checks
# expiry. Both are workload identities: GitHub OIDC in, no client secret EVER
# (they only ever EXIST here — tofu prints their client IDs, which are public
# identifiers, not secrets).
#
#   Apply  — federated credential on the infra repo environment `prod` (the
#            required-reviewer gate), because only a merged, reviewed run may
#            change anything.
#   Read   — federated credentials for pull_request (every PR plan) and
#            ref:refs/heads/main (the scheduled drift + expiry jobs).
#
# Least privilege, and why each role is on the list:
#   Apply (Azure RBAC, subscription): Contributor (create/update the vaults,
#     budgets and other resources the stack owns) + User Access Administrator
#     (the stack assigns Key Vault RBAC roles — Contributor cannot). Scope is
#     the ONE platform subscription, nothing tenant-wide. Plus Storage Blob
#     Data Contributor on stqnsctfstate — the state data plane.
#   Apply (Entra directory roles): Application Administrator (apps + SPs +
#     federated credentials), Groups Administrator (grp-qnsc-* groups),
#     User Administrator (break-glass users), Privileged Role Administrator
#     (the break-glass Global Administrator assignment is IN this stack, so a
#     hand-change must stay plannable — this is the one deliberately
#     privileged grant; audited quarterly §16.2).
#   Read — Reader (subscription), Storage Blob Data Reader (stqnsctfstate,
#     state files are blobs) and Key Vault Reader (metadata only — it must
#     never read a value, §7).

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
  display_name   = "infra-environment-prod"
  description    = "infra repo environment prod (required reviewer gate) — apply runs"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.github_oidc_issuer
  subject        = "${local.infra_subject_base}:environment:prod"
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

# Azure RBAC — apply: Contributor + User Access Administrator on the
# subscription, Storage Blob Data Contributor on the state account.
resource "azurerm_role_assignment" "ci_apply_contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.ci_infra_apply.object_id
}

resource "azurerm_role_assignment" "ci_apply_user_access_admin" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "User Access Administrator"
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

# Entra directory roles — apply only (Read never writes the tenant).
locals {
  ci_apply_directory_roles = [
    "Application Administrator",
    "Groups Administrator",
    "User Administrator",
    "Privileged Role Administrator",
  ]
}

resource "azuread_directory_role_assignment" "ci_apply" {
  for_each = toset(local.ci_apply_directory_roles)

  role_id             = [for r in data.azuread_directory_roles.all.roles : r.template_id if r.display_name == each.value][0]
  principal_object_id = azuread_service_principal.ci_infra_apply.object_id
}

# Client IDs are public identifiers — safe to print; the workflows need them
# (repo variables set after the first apply, see README.md).
output "ci_infra_apply_client_id" {
  description = "QNSC CI Infra client ID — repo variable for apply workflows."
  value       = azuread_application.ci_infra_apply.client_id
}

output "ci_infra_read_client_id" {
  description = "QNSC CI Infra Read client ID — repo variable for plan/drift workflows."
  value       = azuread_application.ci_infra_read.client_id
}
