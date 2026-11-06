# ── Resource-provider registration for live/identity ───────────────────────
#
# The Key Vault alert workspace (kv_alerts.tf) failed the owner's apply with
# 409 MissingSubscriptionRegistration for `Microsoft.OperationalInsights` on
# `azurerm_log_analytics_workspace.kv_audit`. The provider was never registered
# on this subscription — the rest of the stack only used namespaces that were
# already on.
#
# Azure needs each resource provider registered once per subscription before a
# resource of that namespace can be created. Registering it in code means the
# next environment (or a rebuilt subscription) does not depend on somebody
# remembering a click in the portal.
#
# WHY THESE NAMESPACES
#   Microsoft.OperationalInsights  the Log Analytics workspace, the query
#                                  surface behind the Key Vault audit alerts.
#   Microsoft.Insights             ALREADY registered on this subscription:
#                                  action groups, Activity Log alerts and
#                                  scheduled query rules are all
#                                  Microsoft.Insights/* resources, so the
#                                  alert rules themselves need no new
#                                  registration. Kept out of the graph on
#                                  purpose — a second declaration would only
#                                  add a no-op resource address.
#   Microsoft.KeyVault             ALREADY registered: the four vaults and their
#                                  diagnostic settings predate this file.
#
# PERMISSION: registering a provider requires subscription-level write
# permission (Contributor or the Microsoft.Insights/register/action /
# Microsoft.OperationalInsights/register/action action). live/identity is
# owner-applied (this stack is NOT_PLANNABLE in CI), so the person running the
# plan/apply must be the owner — the CI read identity cannot register anything.
# If an automated apply is ever added for this stack, that identity needs
# `Microsoft.OperationalInsights/register/action` at subscription scope, or
# this resource must be removed and the prerequisite documented instead.
#
# ALREADY EXISTS: the owner registered the namespace by hand right after the
# 409, so this file IMPORTS the live registration (block at the bottom) rather
# than creating a second one. The plan is `1 to import, 0 to add`; after the
# apply the state owns the address and a plain create would no longer be
# attempted.
#
# ORDERING: on a FRESH subscription, apply this resource before the resource
# that needs it (a targeted apply), or add `depends_on` from the workspace to
# this resource once both are on main. Terraform does not infer an edge between
# a provider registration and a resource of that provider, so a single fresh
# apply could still race the registration. Irrelevant today: the namespace is
# already registered.

# IMPORT, not create: the owner registered the namespace by hand immediately
# after the 409, so the object already exists. Importing the live registration
# makes the plan `1 to import, 0 to add`; a plain create would fail with
# "already exists — needs to be imported". The subscription id comes from the
# same required variable the rest of the stack uses (owner kit / TF_VAR), never
# a literal in this public repository.
import {
  to = azurerm_resource_provider_registration.operational_insights
  id = "/subscriptions/${var.subscription_id}/providers/Microsoft.OperationalInsights"
}

resource "azurerm_resource_provider_registration" "operational_insights" {
  name = "Microsoft.OperationalInsights"
}
