# ── Access groups ───────────────────────────────────────────────────────────
# Two groups are the root of platform access and were hand-made before this
# stack could own them. Both are ADOPTED here with import blocks (2026-11-06
# drift audit, Med): the objects are written by hand in Entra, membership and
# description stay there, and only the group itself (name, type) is owned.
#
#   grp-qnsc-platform-admins  Key Vault Secrets Officer on all four vaults
#                             (vault_rbac.tf) and, as a repo variable, the
#                             Access door group. Its MEMBERS also drive
#                             var.platform_admin_object_ids (the kit reads the
#                             membership); the two cannot drift because both
#                             read the same live group.
#   grp-qnsc-developers       the engineering doors (rova MCP dev/prod, the
#                             MCP hub, ArgoCD); live/edge reads its id from
#                             the repo variable ENTRA_GRP_DEVELOPERS_ID.
#
# Go/no-go for the import: exactly **2 to import**, 0 to add, **0 `~` (in-place
# change) on either group**, 0 to destroy, 0 to replace. The live attributes
# were checked on 2026-11-06 (securityEnabled true, mailEnabled false, no
# description); the two that matter are named explicitly below.
#
# grp-qnsc-dev-users is the narrow one: the dev web hosts only (rova-dev, opshub-dev, kb-dev) for people who
# test or specify the product (PQA, BA) and need none of the engineering tools. What they may do inside an app
# stays the app's own RBAC. Membership is managed in Entra (admin center), not here.
variable "grp_platform_admins_object_id" {
  type        = string
  description = "Object id of the hand-created grp-qnsc-platform-admins, for its import. Same value as the repo variable ENTRA_GRP_PLATFORM_ADMINS_ID. TF_VAR_grp_platform_admins_object_id, never committed."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.grp_platform_admins_object_id))
    error_message = "grp_platform_admins_object_id must be an Entra object id (GUID)."
  }
}

variable "grp_developers_object_id" {
  type        = string
  description = "Object id of the hand-created grp-qnsc-developers, for its import. Same value as the repo variable ENTRA_GRP_DEVELOPERS_ID. TF_VAR_grp_developers_object_id, never committed."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.grp_developers_object_id))
    error_message = "grp_developers_object_id must be an Entra object id (GUID)."
  }
}

resource "azuread_group" "platform_admins" {
  display_name = "grp-qnsc-platform-admins"
  # The LIVE attributes (checked 2026-11-06): securityEnabled true, mailEnabled
  # false, no description. Named explicitly so the import compares against this
  # shape, not an implicit provider default.
  security_enabled = true
  mail_enabled     = false

  lifecycle {
    # Members AND description are managed in Entra. `description` is not
    # Computed in azuread 3.x, so omitting it here without this ignore would
    # plan it to "" and rewrite the live text.
    ignore_changes = [members, description]
  }
}

resource "azuread_group" "developers" {
  display_name     = "grp-qnsc-developers"
  security_enabled = true
  mail_enabled     = false

  lifecycle {
    ignore_changes = [members, description]
  }
}

import {
  to = azuread_group.platform_admins
  id = "/groups/${var.grp_platform_admins_object_id}"
}

import {
  to = azuread_group.developers
  id = "/groups/${var.grp_developers_object_id}"
}

variable "grp_dev_users_object_id" {
  type        = string
  description = "Object id of the hand-created grp-qnsc-dev-users, for its import (imports.tf). Same value as the infra repo variable ENTRA_GRP_DEV_USERS_ID: TF_VAR_grp_dev_users_object_id=\"$(gh variable get ENTRA_GRP_DEV_USERS_ID -R quynhonsemiconductor/infra)\"."
}

resource "azuread_group" "dev_users" {
  display_name     = "grp-qnsc-dev-users"
  description      = "Dev web hosts only (Cloudflare Access on rova-dev, opshub-dev, kb-dev). No engineering tools."
  security_enabled = true

  lifecycle {
    ignore_changes = [members] # membership is managed in Entra, not in this stack
  }
}

output "grp_dev_users_id" {
  description = "Object id for the repo variable ENTRA_GRP_DEV_USERS_ID (live/edge reads it)."
  value       = azuread_group.dev_users.object_id
}

# grp-qnsc-staff: EVERY employee (software, IC/VLSI, BA, PQA, accounting, management). It gates the PROD internal
# tools (rova / opshub / kb, web and MCP); what a person can do inside an app is that app's own RBAC, because every
# MCP call acts as the signed-in user. Engineering doors (ArgoCD, Proxmox, WARP, the MCP hub) stay on
# grp-qnsc-developers / grp-qnsc-platform-admins. Onboarding adds a person here; offboarding removes them everywhere.
resource "azuread_group" "staff" {
  display_name     = "grp-qnsc-staff"
  description      = "Every employee: prod internal tools (rova, opshub, kb: web + MCP). App RBAC decides the rest."
  security_enabled = true

  lifecycle {
    ignore_changes = [members] # membership is managed in Entra, not in this stack
  }
}

output "grp_staff_id" {
  description = "Object id for the repo variable ENTRA_GRP_STAFF_ID (live/edge reads it)."
  value       = azuread_group.staff.object_id
}
