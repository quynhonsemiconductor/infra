# ── ESO service principals (§7.1) ───────────────────────────────────────────
#
# One app + service principal per ClusterSecretStore in gitops
# platform/eso/stores-onprem.yaml: dev, prod, platform. NONE for kv-qnsc-admin
# — nobody automated reads it (§7.1).
#
# EACH APP HAS EXACTLY ONE CREDENTIAL: a FEDERATED IDENTITY CREDENTIAL. Entra
# trusts a token issued by the cluster's OWN OIDC issuer (below), so there is
# no secret to store, rotate or leak. This is `authType: WorkloadIdentity` in
# stores-onprem.yaml; ESO asks the API server for a service-account token and
# exchanges it at Entra (audience api://AzureADTokenExchange).
#
# NO CERTIFICATE and NO PASSWORD exist, by construction: tests/static.sh fails
# the tree if either ever appears. The certificate credential and the combined
# PEM in 1Password were the cutover path and are gone (README "ESO workload
# identity" records the order they were removed in).
#
# WHY THE ISSUER IS k3s's: k3s sets `service-account-issuer` itself, and a
# `kube-apiserver-arg` override REPLACES it (k3s's util.GetArgs deletes the
# default when the user passes the same flag without a `+`/`-` suffix). The
# issuer URL must be public HTTPS because Entra fetches
# <issuer>/.well-known/openid-configuration and the JWKS from it at token
# exchange. live/onprem-oidc publishes those two documents; the k3s server
# config that sets the issuer is live/onprem-vm/files/k3s/config.yaml. All
# three carry the SAME string, and tests/static.sh fails when they drift.

locals {
  eso = {
    dev = {
      display_name = "QNSC ESO Dev"
      vault_id     = azurerm_key_vault.dev.id
    }
    prod = {
      display_name = "QNSC ESO Prod"
      vault_id     = azurerm_key_vault.purge_protected["prod"].id
    }
    platform = {
      display_name = "QNSC ESO Platform"
      vault_id     = azurerm_key_vault.purge_protected["platform"].id
    }
  }
}

# The cluster's public OIDC issuer. ONE value, three files: this variable,
# live/onprem-oidc (the published discovery document + JWKS) and
# live/onprem-vm/files/k3s/config.yaml (what k3s mints tokens with).
# tests/static.sh fails when they differ.
variable "eso_oidc_issuer" {
  type        = string
  default     = "https://oidc.qnsc.vn/k3s-onprem"
  description = "Issuer URL of the on-prem k3s cluster (no trailing slash). Must equal service-account-issuer in live/onprem-vm/files/k3s/config.yaml and the issuer published by live/onprem-oidc."

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+/[a-z0-9-]+$", var.eso_oidc_issuer))
    error_message = "eso_oidc_issuer must be https://<host>/<path> with no trailing slash — Entra fetches <issuer>/.well-known/openid-configuration and the path segment is not optional."
  }
}

resource "azuread_application" "eso" {
  for_each = local.eso

  display_name     = each.value.display_name
  sign_in_audience = "AzureADMyOrg" # single tenant, app-only; no redirect URIs
}

# The trust Entra puts in the cluster (§7.1 end state). One per app: the
# issuer is the cluster's own OIDC issuer, the subject is the service account
# gitops creates for that store, and the audience is the fixed exchange
# audience ESO always asks the API server for.
#
# The subject string is EXACT — Entra creates a wrong subject happily and the
# token exchange then fails with no error (Microsoft Learn, "Important: if you
# accidentally add the incorrect external workload information in the subject
# setting the federated identity credential is created successfully without
# error"). gitops platform/eso/workload-identity.yaml holds the ServiceAccounts;
# their names must stay eso-dev / eso-prod / eso-platform.
resource "azuread_application_federated_identity_credential" "eso" {
  for_each = local.eso

  application_id = azuread_application.eso[each.key].id
  display_name   = "k3s-onprem-eso-${each.key}"
  description    = "ESO ${each.key} store authenticates with a k3s service-account token (workload identity federation)"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = var.eso_oidc_issuer
  subject        = "system:serviceaccount:external-secrets:eso-${each.key}"
}

resource "azuread_service_principal" "eso" {
  for_each = local.eso

  client_id = azuread_application.eso[each.key].client_id
}

# Client IDs are public identifiers — the owner needs them for the
# `kubectl create secret` of each store (the client-id key in
# stores-onprem.yaml).
output "eso_client_ids" {
  description = "Client (application) id of each ESO SP, keyed dev/prod/platform — the client-id of each cluster Secret."
  value       = { for k, sp in azuread_service_principal.eso : k => sp.client_id }
}
