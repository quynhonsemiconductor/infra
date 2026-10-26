# ── Imports (run at plan time; first apply only) ────────────────────────────
#
# The state backend and the budget were created BY HAND before this stack
# could exist (pre-work (e)). These blocks adopt them in place: `tofu plan`
# proposes one import per line and NO other change — if it shows anything
# else on an imported resource, STOP and reconcile the code with the imported
# value in a reviewed PR; never apply a change to a resource that holds or
# fronts the state.
#
# Once the first apply has recorded them, these blocks are inert and stay
# (OpenTofu ≥ 1.7 keeps them; they are the stack's own provenance note).

import {
  to = azurerm_resource_group.platform
  id = "/subscriptions/${var.subscription_id}/resourceGroups/rg-qnsc-platform"
}

import {
  to = azurerm_storage_account.tfstate
  id = "/subscriptions/${var.subscription_id}/resourceGroups/rg-qnsc-platform/providers/Microsoft.Storage/storageAccounts/stqnsctfstate"
}

import {
  to = azurerm_storage_container.tfstate
  id = "/subscriptions/${var.subscription_id}/resourceGroups/rg-qnsc-platform/providers/Microsoft.Storage/storageAccounts/stqnsctfstate/blobServices/default/containers/tfstate"
}

import {
  to = azurerm_consumption_budget_subscription.monthly
  id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Consumption/budgets/qnsc-platform-monthly"
}
