# ── Access groups ───────────────────────────────────────────────────────────
# grp-qnsc-developers predates this stack (created by hand, its object id is the repo variable
# ENTRA_GRP_DEVELOPERS_ID); it grants the engineering tools too (rova MCP dev/prod, the MCP hub, ArgoCD).
#
# grp-qnsc-dev-users is the narrow one: the dev web hosts only (rova-dev, opshub-dev, kb-dev) for people who
# test or specify the product (PQA, BA) and need none of the engineering tools. What they may do inside an app
# stays the app's own RBAC. Membership is managed in Entra (admin center), not here.
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
