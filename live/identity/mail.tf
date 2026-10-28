# ── Mail service apps (§7.3 — Graph sendMail) ───────────────────────────────
#
# One certificate-only Service app per product per env, named
# "<Product> <Env> Service". The registrations are ADOPTED via import (no new
# ids, so rova #727's recorded client id is unaffected): rova prod (the owner
# hand-creates the registration FIRST — README "Mail service apps") and the
# three EXISTING dev service apps (live since 2026-10-18). NO opshub/kb PROD
# apps — those products are not live in prod; their service apps come with
# their own prod PRs and stay draft until then.
#
# Certificate auth ONLY (§7.2): the PUBLIC half is terraformed from
# TF_VAR_mail_service_certificates (a private key never passes validation —
# tests/static.sh guards the same invariant); the combined PEM (key + cert)
# per app is written to the vault BY THE OWNER through
# `az keyvault secret set --file` (README), consumed by the worker as
# AZURE_CLIENT_CERTIFICATE_PATH. No client secret exists, by construction.
#
# No Mail.* permission anywhere (§7.2): Exchange RBAC
# ("Application Mail.Send" scoped to the product mailbox) is EXCHANGE-side and
# stays owner-run in scripts/owner/mail-prod-tenant/. rova and kb Service
# apps hold NO Graph permissions at all; opshub's five Graph APPLICATION roles
# (identity/door reads) are modeled so the import does not REMOVE them
# (azuread 3.x does not treat required_resource_access as Computed); ids are
# resolved from the msgraph SP — no literal UUIDs.

locals {
  mail_service_apps = {
    rova_prod = {
      display_name          = "Rova Prod Service"
      graph_app_role_values = []
    }
    rova_dev = {
      display_name          = "Rova Dev Service"
      graph_app_role_values = []
    }
    opshub_dev = {
      display_name = "OpsHub Dev Service"
      # Exactly the five live application permissions (identity/door reads);
      # never Mail.Send (§7.3).
      graph_app_role_values = [
        "SecurityEvents.Read.All",
        "DeviceManagementManagedDevices.Read.All",
        "User.Read.All",
        "User.EnableDisableAccount.All",
        "User.RevokeSessions.All",
      ]
    }
    kb_dev = {
      display_name          = "KB Dev Service"
      graph_app_role_values = []
    }
  }
}

variable "mail_service_object_ids" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "Object ids of the EXISTING mail service-app registrations (adopted, not replaced). rova_prod's registration is hand-created by the owner FIRST (README). TF_VAR_mail_service_object_ids exported by the owner, never committed."
}

variable "mail_service_sp_object_ids" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "Object ids of the mail service apps' service principals (the enterprise-application objects, NOT the app-registrations object ids). TF_VAR_mail_service_sp_object_ids exported by the owner, never committed."
}

variable "mail_service_certificates" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "PEM PUBLIC certificate for each mail service app, keyed like local.mail_service_apps. Generated locally by the owner (openssl, RSA 2048, ≤ 24 months), passed through TF_VAR_mail_service_certificates, never committed. A private key must never be passed."

  validation {
    condition = alltrue([
      for pem in values(var.mail_service_certificates) :
      can(regex("-----BEGIN CERTIFICATE-----", pem)) && !can(regex("PRIVATE KEY", pem))
    ])
    error_message = "Every mail_service_certificates value must be a PEM PUBLIC certificate (BEGIN CERTIFICATE); a private key is never accepted."
  }
}

resource "azuread_application" "mail_service" {
  for_each = local.mail_service_apps

  display_name     = each.value.display_name
  sign_in_audience = "AzureADMyOrg" # single tenant, app-only; no redirect URIs

  # rova and kb: NO required_resource_access at all (their runbooks require
  # none — a hand-created registration's default delegated User.Read entry is
  # REMOVED on apply, an intended change named in the README). opshub: exactly
  # the five live application roles, ids resolved from the msgraph SP.
  dynamic "required_resource_access" {
    for_each = length(each.value.graph_app_role_values) > 0 ? [1] : []
    content {
      resource_app_id = data.azuread_service_principal.msgraph.client_id
      dynamic "resource_access" {
        for_each = each.value.graph_app_role_values
        content {
          id   = data.azuread_service_principal.msgraph.app_role_ids[resource_access.value]
          type = "Role"
        }
      }
    }
  }
}

resource "azuread_application_certificate" "mail_service" {
  for_each = local.mail_service_apps

  application_id = azuread_application.mail_service[each.key].id
  type           = "AsymmetricX509Cert"
  value          = var.mail_service_certificates[each.key]
  encoding       = "pem"

  # Rotation issues the NEW credential before the old one is removed, so the
  # SP is never left without a certificate mid-apply; the worker's PEM file is
  # swapped right after (README "Rotation").
  lifecycle {
    create_before_destroy = true
  }
}

resource "azuread_service_principal" "mail_service" {
  for_each = azuread_application.mail_service

  client_id = each.value.client_id
}

# ── Adoption: import the existing registrations, do not create new ones ─────
import {
  to = azuread_application.mail_service["rova_prod"]
  id = "/applications/${var.mail_service_object_ids.rova_prod}"
}
import {
  to = azuread_application.mail_service["rova_dev"]
  id = "/applications/${var.mail_service_object_ids.rova_dev}"
}
import {
  to = azuread_application.mail_service["opshub_dev"]
  id = "/applications/${var.mail_service_object_ids.opshub_dev}"
}
import {
  to = azuread_application.mail_service["kb_dev"]
  id = "/applications/${var.mail_service_object_ids.kb_dev}"
}
import {
  to = azuread_service_principal.mail_service["rova_prod"]
  id = "/servicePrincipals/${var.mail_service_sp_object_ids.rova_prod}"
}
import {
  to = azuread_service_principal.mail_service["rova_dev"]
  id = "/servicePrincipals/${var.mail_service_sp_object_ids.rova_dev}"
}
import {
  to = azuread_service_principal.mail_service["opshub_dev"]
  id = "/servicePrincipals/${var.mail_service_sp_object_ids.opshub_dev}"
}
import {
  to = azuread_service_principal.mail_service["kb_dev"]
  id = "/servicePrincipals/${var.mail_service_sp_object_ids.kb_dev}"
}

# Client ids are public identifiers — rova #727 records the rova_prod one as
# its Graph client id; the dev values land in the dev secret bundles.
output "mail_service_client_ids" {
  description = "Client (application) id of each mail service app — the Graph client id per product/env. Never carries a secret."
  value       = { for k, app in azuread_application.mail_service : k => app.client_id }
}
