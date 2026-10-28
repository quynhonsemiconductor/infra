# ── Mail service apps (§7.3 — Graph sendMail) ───────────────────────────────
#
# One certificate-only Service app per product per env, named
# "<Product> <Env> Service". The registrations are ADOPTED via import (no new
# ids): rova prod (the owner hand-creates the registration FIRST — README
# "Mail service apps") and the three EXISTING dev service apps (live since
# 2026-10-18, reconciled to the 2026-10-28 exports). NO opshub/kb PROD apps —
# those products are not live in prod; their service apps come with their own
# prod PRs and stay draft until then.
#
# The DEV certificates are ADOPTED too (SA decision — no rotation): one
# azuread_application_certificate per dev app, imported by the azuread 3.10
# parse.CertificateID form — EXACTLY "{app OBJECT id}/certificate/{keyId}"
# (ObjectSubResourceID: 3 slash-parts, bare UUID, no /applications/ prefix;
# keyIds via TF_VAR_mail_service_cert_key_ids — public identifiers), the
# VALUE being the public certificate already in 1Password ("Entra mail cert –
# <product>-dev – certificate"). Only rova_prod's certificate is CREATED (new
# keypair, README). ignore_changes on value/encoding keeps the imported certs
# imported (see the resource comment).
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
# apps hold NO Graph permissions at all; opshub_dev models EXACTLY the three
# LIVE application roles (2026-10-28 export; the write roles come later in
# their own PR) so the import does not REMOVE them (azuread 3.x does not
# treat required_resource_access as Computed); ids are resolved from the
# msgraph SP — no literal UUIDs.

locals {
  mail_service_apps = {
    rova_prod = {
      display_name = "Rova Prod Service"
      notes        = "github.com/quynhonsemiconductor/rova"
      # The one Graph permission the plan gives the rova Service app (§7.3,
      # H-D14, backlog P0-7): tenant-wide guest invite — the sign-in apps
      # must keep NO application permissions. The app UPDATE is in this
      # plan; the ADMIN CONSENT is a separate manual step right after apply
      # (az ad app permission admin-consent, README step 4).
      graph_app_role_values = ["User.Invite.All"]
    }
    rova_dev = {
      display_name          = "Rova Dev Service"
      notes                 = "github.com/quynhonsemiconductor/rova"
      graph_app_role_values = []
    }
    opshub_dev = {
      display_name = "OpsHub Dev Service"
      notes        = "github.com/quynhonsemiconductor/opshub"
      # Exactly the three LIVE application roles (2026-10-28 export); never
      # Mail.Send (§7.3). The write roles are a later, separate PR.
      graph_app_role_values = [
        "DeviceManagementManagedDevices.Read.All",
        "SecurityEvents.Read.All",
        "User.Read.All",
      ]
    }
    kb_dev = {
      display_name          = "KB Dev Service"
      notes                 = "github.com/quynhonsemiconductor/qnsc-kb-backend"
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

variable "mail_service_cert_key_ids" {
  type = object({
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "keyId of the EXISTING certificate credential on each dev service app, from the owner's `az ad app show` export (keyCredentials[].keyId) — public identifiers, used only to build the import ids. TF_VAR_mail_service_cert_key_ids (JSON), never committed."

  validation {
    condition = alltrue([
      for id in values(var.mail_service_cert_key_ids) :
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id))
    ])
    error_message = "Every mail_service_cert_key_ids value must be a GUID."
  }
}

variable "mail_service_certificates" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "PEM PUBLIC certificate per app, keyed like local.mail_service_apps. Dev values are the certificates ALREADY LIVE (1Password 'Entra mail cert – <product>-dev – certificate' — the same bytes the export shows); rova_prod's comes from the owner's NEW keypair (README step 3). Passed through TF_VAR_mail_service_certificates, never committed. A private key must never be passed."

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
  notes            = each.value.notes
  sign_in_audience = "AzureADMyOrg" # single tenant, app-only; no redirect URIs

  # rova and kb: NO required_resource_access at all (their runbooks require
  # none — a hand-created registration's default delegated User.Read entry is
  # REMOVED on apply, an intended change named in the README). opshub_dev:
  # exactly the three live application roles, ids resolved from the msgraph
  # SP.
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

  # azuread 3.10: value/encoding are ForceNew AND the read never sets them, so
  # an imported certificate would plan a REPLACE (delete the live dev cert —
  # it breaks the workers). value/encoding are write-only config here: ignore
  # changes so imported certs stay imported and the secret's bytes are the
  # source of truth. Any plan showing a certificate "must be replaced" is a
  # STOP (README go/no-go).
  #
  # Rotation is still deliberate: issue the NEW credential (apply) before the
  # old one is removed, then swap the worker's PEM (README "Rotation").
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [value, encoding]
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
# Dev certificates: ADOPTED (SA decision — no rotation). Import id shape
# (azuread 3.10 parse.CertificateID = ObjectSubResourceID): exactly
# "{app OBJECT id}/certificate/{keyId}" — 3 slash-parts, NO /applications/
# prefix. rova_prod's certificate is the one create in this apply.
import {
  to = azuread_application_certificate.mail_service["rova_dev"]
  id = "/applications/${var.mail_service_object_ids.rova_dev}/certificate/${var.mail_service_cert_key_ids.rova_dev}"
}
import {
  to = azuread_application_certificate.mail_service["opshub_dev"]
  id = "/applications/${var.mail_service_object_ids.opshub_dev}/certificate/${var.mail_service_cert_key_ids.opshub_dev}"
}
import {
  to = azuread_application_certificate.mail_service["kb_dev"]
  id = "/applications/${var.mail_service_object_ids.kb_dev}/certificate/${var.mail_service_cert_key_ids.kb_dev}"
}

# Client ids are public identifiers — rova #727 records the rova_prod one as
# its Graph client id; the dev values land in the dev secret bundles.
output "mail_service_client_ids" {
  description = "Client (application) id of each mail service app — the Graph client id per product/env. Never carries a secret."
  value       = { for k, app in azuread_application.mail_service : k => app.client_id }
}
