# ── Mail service apps (§7.3 — Graph sendMail) ───────────────────────────────
#
# One certificate-only Service app per product per env, named
# "<Product> <Env> Service". The registrations are ADOPTED via import (no new
# ids): rova prod (hand-made by the owner on 2026-11-01, already with its
# certificate — README "Mail service apps") and the three EXISTING dev service apps (live since
# 2026-10-18, reconciled to the 2026-10-28 exports). NO opshub/kb PROD apps
# here — opshub prod's service app is CREATED in prod_apps.tf (with its
# certificate, owner-supplied public half); kb prod's comes with its own prod
# PR once its hostnames and permissions are decided (README).
#
# The DEV certificates are ADOPTED too (SA decision — no rotation): one
# azuread_application_certificate per dev app, imported by the azuread 3.10
# parse.CertificateID form — EXACTLY "{app OBJECT id}/certificate/{keyId}"
# (ObjectSubResourceID: 3 slash-parts, bare UUID, no /applications/ prefix;
# keyIds PINNED in local.mail_service_cert_key_ids — public identifiers, never a
# variable), the VALUE being the public certificate already in 1Password
# ("Entra mail cert – <product>-dev – certificate"). rova_prod's certificate is
# ADOPTED too (the hand-made app already has it; README). ignore_changes on
# value/encoding keeps the imported certs imported (see the resource comment).
#
# ADDITIONAL credentials (rotation) are adopted the same way, one resource per
# credential, keyed by its keyId, the ids PINNED in
# local.mail_service_rotated_cert_key_ids; the PEM map
# (TF_VAR_mail_service_rotated_certificates) supplies values only.
# "KB Dev Service" carries TWO today: the 2026-10-18 credential imported above
# and a Key Vault-generated one appended by the owner on 2026-11-04
# (sa-notes/kb-dev-secrets.sh; the vault keeps the private key, Entra the
# public half). Both are imported, exactly as the old one is: a plan that
# CREATES a certificate, or replaces one, would add a third credential or
# drop the one the worker authenticates with — STOP (README go/no-go). The
# set is empty for every other app.
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
  description = "Object ids of the EXISTING mail service-app registrations (adopted, not replaced). rova_prod's registration was hand-made by the owner on 2026-11-01 (README). TF_VAR_mail_service_object_ids exported by the owner, never committed."
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

# ── PINNED credential keyIds — reviewed, never derived, never owner-supplied ──
# A keyId is a public identifier. It is PINNED here on purpose: a value that
# arrives through a variable can be missing (the for_each empties) or mistyped,
# and either DESTROYS the live credential on the next apply —
# create_before_destroy does not protect a destroy. Changing this map is a
# reviewed code change.
#
#   mail_service_cert_key_ids          slot  -> the credential under
#                                              azuread_application_certificate.mail_service["<slot>"]
#   mail_service_rotated_cert_key_ids  slot  -> ADDITIONAL credentials, each under
#                                              mail_service_rotated["<keyId>"]
#
# scripts/owner/identity-env/identity-env.sh parses these two blocks (exact
# shape: two-space indent, one entry per line) and ASSERTS every id exists in
# Entra, every live credential is pinned, and every startDateTime is present;
# it never decides which credential is which. Values read from Entra on
# 2026-11-04.
locals {
  # Each value is named `key_id` on purpose: the public-repo leak guard allows a
  # GUID only where the line names it as the value of an allowlisted key
  # (.github/leak-guard-allowlist.txt, `key:key_id`). Nothing else may be
  # suppressed.
  mail_service_cert_key_ids = {
    rova_prod  = { key_id = "f0b1686d-9eea-47e5-ba16-eb2566ee5709" }
    rova_dev   = { key_id = "687e178e-feae-4ebc-a881-b5d2f0ae5357" }
    opshub_dev = { key_id = "ddf98e3f-48f1-43be-9455-5e92b4044312" }
    kb_dev     = { key_id = "fc90ec3d-d5a4-4747-8c8b-b64a1fd89c30" } # the 2026-10-18 credential
  }

  mail_service_rotated_cert_key_ids = {
    kb_dev = [{ key_id = "e967b988-1892-4f56-975a-2ff7d02f0049" }] # the 2026-11-04 Key Vault credential
  }

  # Flattened so each credential gets its own address, keyed by keyId.
  mail_service_rotated_credentials = merge([
    for slot, creds in local.mail_service_rotated_cert_key_ids : {
      for c in creds : c.key_id => { slot = slot, key_id = c.key_id }
    }
  ]...)
}

variable "mail_service_certificates" {
  type = object({
    rova_prod  = string
    rova_dev   = string
    opshub_dev = string
    kb_dev     = string
  })
  description = "PEM PUBLIC certificate of the PRIMARY credential per app (the keyId pinned in local.mail_service_cert_key_ids), keyed like local.mail_service_apps. The kit reads them from the Entra app itself; rova_prod's is the PUBLIC half of the certificate already on the hand-made app. Passed through TF_VAR_mail_service_certificates, never committed. A private key must never be passed. Required: no default, so a plan without it fails instead of dropping a resource."

  validation {
    condition = alltrue([
      for pem in values(var.mail_service_certificates) :
      can(regex("-----BEGIN CERTIFICATE-----", pem)) && !can(regex("PRIVATE KEY", pem))
    ])
    error_message = "Every mail_service_certificates value must be a PEM PUBLIC certificate (BEGIN CERTIFICATE); a private key is never accepted."
  }
}

variable "mail_service_rotated_certificates" {
  type        = map(string)
  description = "PEM PUBLIC certificate of each ADDITIONAL credential, keyed by its keyId (the keys pinned in local.mail_service_rotated_cert_key_ids). Today exactly one entry for KB Dev's 2026-11-04 Key Vault-generated credential. Built by scripts/owner/identity-env/identity-env.sh from the Entra app itself (public half only), never committed. REQUIRED and with no default: a missing value must stop the plan (invalid index), never empty the for_each and destroy a live credential."

  validation {
    condition = alltrue([
      for id, pem in var.mail_service_rotated_certificates :
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id)) &&
      can(regex("-----BEGIN CERTIFICATE-----", pem)) &&
      !can(regex("PRIVATE KEY", pem))
    ])
    error_message = "mail_service_rotated_certificates keys must be credential keyIds (GUIDs) and every certificate a PEM PUBLIC certificate (BEGIN CERTIFICATE); a private key is never accepted."
  }
}

variable "mail_service_graph_grant_ids" {
  type        = map(string)
  description = "Assignment id of every Graph application-role grant the service apps ALREADY hold, keyed like local.mail_service_graph_grants (\"<slot>/<role value>\"). Built by scripts/owner/identity-env/identity-env.sh from the live appRoleAssignments (read-only). The grants exist (admin consent); importing them is mandatory, or the plan adds duplicates. REQUIRED and with no default: once imported, a missing map would empty the for_each and DROP the grants, so a plan without it must stop instead."
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
    # The credential is LIVE and read by the worker: no plan may ever drop it.
    # Retiring one is the reviewed procedure in the README (removed block with
    # destroy = false, then the Entra delete by hand), never an apply of this
    # resource.
    prevent_destroy = true
  }
}

resource "azuread_application_certificate" "mail_service_rotated" {
  for_each = local.mail_service_rotated_credentials

  application_id = azuread_application.mail_service[each.value.slot].id
  type           = "AsymmetricX509Cert"
  value          = var.mail_service_rotated_certificates[each.key]
  encoding       = "pem"

  # Same write-only shape as the primary certificate above: the credential is
  # ADOPTED (import block below), so a plan must never create or replace it.
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [value, encoding]
    prevent_destroy       = true
  }
}

resource "azuread_service_principal" "mail_service" {
  for_each = azuread_application.mail_service

  client_id = each.value.client_id
}

# ── Graph application-role grants: declared AND managed ─────────────────────
# required_resource_access DECLARES a role; the grant (an appRoleAssignment on
# the Microsoft Graph service principal) is a separate object. Admin consent
# created the grants for rova_prod (User.Invite.All) and opshub_dev (the three
# read roles) before this stack managed them — see the 2026-11-04 audit in the
# README. One resource per declared role: a REVOKED grant shows as a create in
# the plan (STOP — the app needs it), and the declaration and the grant cannot
# drift. A live grant that is NOT declared stays invisible here; the README's
# read-only audit is what finds those.
locals {
  mail_service_graph_grants = merge([
    for slot, app in local.mail_service_apps : {
      for role in app.graph_app_role_values : "${slot}/${role}" => {
        slot = slot
        role = role
      }
    }
  ]...)
}

resource "azuread_app_role_assignment" "mail_service" {
  for_each = local.mail_service_graph_grants

  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.value.role]
  principal_object_id = azuread_service_principal.mail_service[each.value.slot].object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
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
# prefix. rova_prod's certificate is ADOPTED the same way: the hand-made app
# already carries the credential whose public half is inside
# kv-qnsc-prod/rova-prod-graph-cert, so creating a second one would add a
# duplicate key credential.
import {
  to = azuread_application_certificate.mail_service["rova_prod"]
  id = "${var.mail_service_object_ids.rova_prod}/certificate/${local.mail_service_cert_key_ids.rova_prod.key_id}"
}
import {
  to = azuread_application_certificate.mail_service["rova_dev"]
  id = "${var.mail_service_object_ids.rova_dev}/certificate/${local.mail_service_cert_key_ids.rova_dev.key_id}"
}
import {
  to = azuread_application_certificate.mail_service["opshub_dev"]
  id = "${var.mail_service_object_ids.opshub_dev}/certificate/${local.mail_service_cert_key_ids.opshub_dev.key_id}"
}
import {
  to = azuread_application_certificate.mail_service["kb_dev"]
  id = "${var.mail_service_object_ids.kb_dev}/certificate/${local.mail_service_cert_key_ids.kb_dev.key_id}"
}
# Additional (rotated) credentials: same CertificateID shape, each keyId pinned
# in local.mail_service_rotated_cert_key_ids. An import of a resource that is
# ALREADY in state with the SAME id is a NO-OP (verified with OpenTofu 1.12,
# 2026-11-04), so these blocks stay in the tree after the apply; they are the
# authoritative statement that the credential is managed here.
import {
  for_each = local.mail_service_rotated_credentials
  to       = azuread_application_certificate.mail_service_rotated[each.key]
  id       = "${var.mail_service_object_ids[each.value.slot]}/certificate/${each.value.key_id}"
}
# The GRANTS that admin consent already created. The id is the ASSIGNMENT id
# (not the role id) under the Graph service principal, the resource of every
# one of these grants. A key with no matching declared role fails the plan on
# the resource address — reconcile mail.tf instead of guessing.
import {
  for_each = var.mail_service_graph_grant_ids
  to       = azuread_app_role_assignment.mail_service[each.key]
  id       = "/servicePrincipals/${data.azuread_service_principal.msgraph.object_id}/appRoleAssignedTo/${each.value}"
}

# Client ids are public identifiers — rova #727 records the rova_prod one as
# its Graph client id; the dev values land in the dev secret bundles.
output "mail_service_client_ids" {
  description = "Client (application) id of each mail service app — the Graph client id per product/env. Never carries a secret."
  value       = { for k, app in azuread_application.mail_service : k => app.client_id }
}
