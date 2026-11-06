# ── Extra OpsHub Dev `admin` holders (tester assignments) ───────────────────
#
# The `admin` app role on OpsHub Dev is held by the platform admins through
# azuread_app_role_assignment.opshub_dev_admin (var.platform_admin_object_ids)
# and, since 2026-08-31, by hand-assigned testers who are NOT platform admins
# and NOT in grp-qnsc-platform-admins (2026-11-06 drift audit, Med). This file
# adopts those app-role ASSIGNMENTS so the next apply does not delete them,
# without putting a person's name, UPN or object id in this public repo: the
# owner apply kit resolves IDENTITY_DEV_APP_EXTRA_ADMINS to object ids and to
# the LIVE assignment ids (the import targets).
#
# Scope: DEV only. Prod admins stay exactly the platform admins — a prod key
# fails the variable validation. A removal from the owner's list removes the
# assignment on the next apply (review before you do it).
#
# N-M10 still holds: this is a DELEGATED USER role assignment, not an
# application permission; opshub reads the signed-in user's `roles` claim.

variable "dev_app_extra_admin_object_ids" {
  type        = map(list(string))
  default     = {}
  description = "Extra holders of the OpsHub Dev `admin` app role, keyed by app (opshub_dev only), as user object ids. Built by scripts/owner/identity-env/identity-env.sh from IDENTITY_DEV_APP_EXTRA_ADMINS (app=upn,...); never committed."

  validation {
    condition = alltrue([
      for app, ids in var.dev_app_extra_admin_object_ids :
      app == "opshub_dev" &&
      length(ids) > 0 &&
      alltrue([
        for id in ids :
        can(regex("^[A-Za-z0-9_-]{20,}$", id))
      ])
    ])
    error_message = "dev_app_extra_admin_object_ids accepts OpsHub Dev only, each a non-empty list of user object ids (GUIDs). A prod key is rejected."
  }
}

variable "dev_app_extra_admin_assignment_ids" {
  type        = map(string)
  default     = {}
  description = "LIVE app-role assignment ids for the extras above, keyed '<app>/<user object id>', read from the app's appRoleAssignedTo by the kit. Entra appRoleAssignment ids are OPAQUE base64url strings (about 43 characters), NOT GUIDs. These ids feed the import blocks ONLY; an entry that is live but missing here would plan a DUPLICATE create (Entra answers 409). Never committed."

  validation {
    condition = alltrue([
      for key, id in var.dev_app_extra_admin_assignment_ids :
      can(regex("^opshub_dev/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", key)) &&
      can(regex("^[A-Za-z0-9_-]{20,}$", id))
    ])
    error_message = "dev_app_extra_admin_assignment_ids keys must be 'opshub_dev/<user object id>' and values Entra appRoleAssignment ids (opaque base64url, at least 20 chars) — they are NOT GUIDs."
  }
}

locals {
  # Flatten the per-app lists into one map of assignment instances:
  # "<app>/<user object id>" => the principal it assigns.
  dev_extra_admin_principals = merge([
    for app, ids in var.dev_app_extra_admin_object_ids :
    { for id in ids : "${app}/${id}" => { app = app, principal_object_id = id } }
  ]...)
}

resource "azuread_app_role_assignment" "dev_extra_admin" {
  for_each = local.dev_extra_admin_principals

  # The admin role id is the live one already modelled for the platform admins
  # (var.opshub_dev_app_role_ids["admin"]); this assignment adds a principal,
  # it never changes the role.
  app_role_id         = var.opshub_dev_app_role_ids["admin"]
  principal_object_id = each.value.principal_object_id
  resource_object_id  = azuread_service_principal.signin[each.value.app].object_id

  lifecycle {
    # Every import key must be a DECLARED principal, or `to` names an instance
    # that does not exist and the whole plan fails with a confusing message.
    precondition {
      condition = alltrue([
        for key in keys(var.dev_app_extra_admin_assignment_ids) :
        contains(keys(local.dev_extra_admin_principals), key)
      ])
      error_message = "dev_app_extra_admin_assignment_ids has a key with no matching user in dev_app_extra_admin_object_ids. Re-run the owner kit; do not edit the map by hand."
    }

    # A platform admin already gets `admin` from opshub_dev_admin. Listing one
    # here would put the same assignment under two addresses (a plan error, or
    # a duplicate create). Fail early with the reason.
    precondition {
      condition = alltrue([
        for ids in values(var.dev_app_extra_admin_object_ids) :
        alltrue([for id in ids : !contains(var.platform_admin_object_ids, id)])
      ])
      error_message = "dev_app_extra_admin_object_ids contains a platform admin, who already holds `admin` through var.platform_admin_object_ids. Remove that UPN from IDENTITY_DEV_APP_EXTRA_ADMINS."
    }
  }
}

# Import the assignments that ALREADY exist (the hand-made tester grants).
# A live assignment absent from this map would be planned as a CREATE and
# Entra rejects the duplicate (409) — the kit reads them all before a plan.
import {
  for_each = var.dev_app_extra_admin_assignment_ids
  to       = azuread_app_role_assignment.dev_extra_admin[each.key]
  id       = "/servicePrincipals/${azuread_service_principal.signin[split("/", each.key)[0]].object_id}/appRoleAssignedTo/${each.value}"
}
