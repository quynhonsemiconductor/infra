# ── ESO service principals (§7.1) ───────────────────────────────────────────
#
# One app + service principal per ClusterSecretStore in gitops
# platform/eso/stores-onprem.yaml: dev, prod, platform. NONE for kv-qnsc-admin
# — nobody automated reads it (§7.1).
#
# Certificate auth ONLY (stores-onprem.yaml: ServicePrincipal + the
# clientCertificate secret). No password credential exists, by construction —
# tests/static.sh fails the tree if one is ever added. The owner generates
# each keypair LOCALLY; only the PUBLIC certificate reaches the directory and
# the state, never the private key (§7: certificates are attached by their
# public half). The combined PEM (certificate + private key, exactly what
# ESO's tls.pem reads) lives in 1Password and is hand-applied into the
# cluster as the store's Secret (README "ESO SP certificates", §14 step 2).

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

variable "eso_certificates" {
  type = object({
    dev      = string
    prod     = string
    platform = string
  })
  description = "PEM public certificate for each ESO SP, keyed like local.eso. Generated locally by the owner (openssl, RSA 2048, ≤ 12 months), passed through TF_VAR_eso_certificates, never committed. A private key must never be passed."

  validation {
    condition = alltrue([
      for pem in values(var.eso_certificates) :
      can(regex("-----BEGIN CERTIFICATE-----", pem)) && !can(regex("PRIVATE KEY", pem))
    ])
    error_message = "Every eso_certificates value must be a PEM PUBLIC certificate (BEGIN CERTIFICATE); a private key is never accepted."
  }
}

resource "azuread_application" "eso" {
  for_each = local.eso

  display_name     = each.value.display_name
  sign_in_audience = "AzureADMyOrg" # single tenant, app-only; no redirect URIs
}

resource "azuread_application_certificate" "eso" {
  for_each = local.eso

  application_id = azuread_application.eso[each.key].id
  type           = "AsymmetricX509Cert"
  value          = var.eso_certificates[each.key]
  encoding       = "pem"

  # Rotation issues the NEW credential before the old one is removed, so the
  # SP is never left without a certificate mid-apply. The cluster Secret
  # (tls.pem) is swapped right after apply — see README "Rotation".
  lifecycle {
    create_before_destroy = true
  }
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
