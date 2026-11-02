# ── Proxmox identities as code: the user, the API token, the role, the ACLs ───
#
# Everything in this file EXISTS on pve01 (created by hand with pveum when the stack
# was bootstrapped) and is IMPORTED (imports.tf), never recreated. The target after the
# import is a plan that reports NO CHANGES; a diff means this file disagrees with the host
# and the file is what changes (README "Proxmox API objects").
#
# THE TOKEN SECRET IS NOT HERE. `proxmox_user_token.value` exists only on CREATE and is
# unreadable afterwards; an import leaves it null, so nothing rotates and nothing is written to
# state. This stack authenticates with that very token (providers.tf, TF_VAR_proxmox_api_token):
# the resource describes it, it must never be destroyed or recreated from here, hence
# prevent_destroy on all of it.
#
# Not managed: the `root@pam` account, realms, other users/groups, and anything created by
# the Proxmox installer.

# Sys.Modify at the node, nothing else: the VM resource sets `startup { order = ... }`, which
# Proxmox gates behind Sys.Modify and which PVEAdmin does not carry.
resource "proxmox_virtual_environment_role" "tofu_startup_order" {
  role_id    = "TofuStartupOrder"
  privileges = ["Sys.Modify"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_virtual_environment_user" "terraform" {
  user_id = "terraform@pve"
  # No password: the account is an API identity, it never logs in to the UI. An import cannot read
  # one back, and setting one here would be a write.

  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_user_token" "tofu" {
  user_id    = proxmox_virtual_environment_user.terraform.user_id
  token_name = "tofu"
  # `pveum user token list terraform@pve` shows `privsep`. With 1 (the Proxmox default) the token has
  # its own ACLs, listed below under token_id; with 0 it inherits the user's.
  privileges_separation = var.proxmox_token_privilege_separation

  lifecycle {
    prevent_destroy = true
  }
}

# The ACL entries `pveum acl list` shows for this identity, one map entry each (site values: the
# paths and roles come from the owner's local tfvars, see site.tfvars.example). principal is the
# user (`terraform@pve`) or the token (`terraform@pve!tofu`).
resource "proxmox_acl" "managed" {
  for_each = var.pve_acls

  path      = each.value.path
  role_id   = each.value.role_id
  propagate = each.value.propagate
  user_id   = each.value.user_id
  token_id  = each.value.token_id

  lifecycle {
    prevent_destroy = true
  }
}
