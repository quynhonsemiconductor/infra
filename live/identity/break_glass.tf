# ── Break-glass accounts (ONPREM-PLAN §15.1 f, §18 H9) ──────────────────────
#
# TWO cloud-only emergency admin accounts. They exist so that a broken Entra
# configuration (Conditional Access mistake, IdP outage, federated lockout)
# can never leave the tenant unreachable:
#   - cloud-only (no federation), no mailbox, no licences;
#   - members of the **`break-glass` Entra group** (created here) — every
#     Conditional Access policy in the tenant MUST add this group to its
#     `exclude` list (requirement, verified at each quarterly review §16.2 —
#     an "exclude by not matching" rule would be fragile);
#   - **Microsoft's mandatory admin MFA applies to them** — register FIDO2
#     keys for both accounts and keep the keys with the envelope;
#   - they hold Global Administrator as a **permanent ACTIVE assignment**
#     (not PIM-eligible: break-glass means NOW) — audited quarterly;
#   - **created DISABLED, nothing secret in state, no tofu-managed
#     password**: throwaway provisioning credential. The OWNER then sets the
#     real password in Entra, registers FIDO2 keys (Microsoft's mandatory
#     admin MFA applies), stores it all in **1Password** (not the vault —
#     these must be reachable even when Azure is the thing that is broken),
#     and **enables the account**. tofu ignores password,
#     force_password_change AND account_enabled forever — an apply can
#     never disable an emergency account.
#
# NEVER used for daily work. Sign-ins alert (Entra; the accounts' names make
# any use obvious in the sign-in log).

variable "break_glass_upn_domain" {
  type        = string
  description = "UPN domain for the break-glass accounts (the tenant's primary domain). TF_VAR_break_glass_upn_domain."
}

# Throwaway provisioning credential: the OWNER immediately resets the
# password in Entra (stores the real one in 1Password) — the value below is
# never used for a real sign-in and is ignored by tofu afterwards.
# Entra rejects a password that contains the username (or parts of the
# display name), so the placeholder must NOT embed each.key (bg1/bg2 are the
# usernames). A fixed placeholder meeting Entra complexity (upper, lower,
# digit, symbol, 8-256 chars) is used for both accounts.
resource "azuread_user" "break_glass" {
  for_each = { bg1 = "Break Glass 1", bg2 = "Break Glass 2" }

  user_principal_name = "${each.key}@${var.break_glass_upn_domain}"
  display_name        = each.value
  # NO job title, department or manager: an offboarding sweep must never
  # touch them.
  password              = "Disabled-Placeholder-2026!"
  force_password_change = true
  account_enabled       = false # owner enables AFTER password + FIDO2 + 1Password

  lifecycle {
    ignore_changes = [password, force_password_change, account_enabled]
  }
}

resource "azuread_group" "break_glass" {
  display_name     = "break-glass"
  security_enabled = true
  members          = [for u in azuread_user.break_glass : u.object_id]

  lifecycle {
    ignore_changes = [members] # membership is emergency-controlled by hand
  }
}

# Global Administrator, permanent ACTIVE assignment (not PIM-eligible:
# break-glass means NOW, no approval hop). Two-role tenants are small
# enough that this is auditable.
data "azuread_directory_roles" "all" {}

locals {
  global_admin_template_id = [
    for r in data.azuread_directory_roles.all.roles : r.template_id
    if r.display_name == "Global Administrator"
  ][0]
}

resource "azuread_directory_role_assignment" "break_glass" {
  for_each            = azuread_user.break_glass
  role_id             = local.global_admin_template_id
  principal_object_id = azuread_user.break_glass[each.key].object_id
}

output "break_glass_upns" {
  description = "UPNs of the break-glass accounts (for the envelope + expiry-check). Never carries a password."
  value       = { for k, u in azuread_user.break_glass : k => u.user_principal_name }
}
