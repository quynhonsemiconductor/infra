# VM 100 (k3s-01) already exists on pve01, created by hand from template 9000
# on 2026-10-21. It is IMPORTED, never recreated: the import block runs on the
# first apply, and the read-back must produce a plan that reports NO CHANGES
# for the VM (README, "First apply"). Any diff at all is vm.tf disagreeing
# with the live machine.
#
# After the import succeeds the block is a no-op and stays here as the record
# of where the VM came from.
import {
  to = proxmox_virtual_environment_vm.k3s_01
  id = "${var.proxmox_node}/${var.vm_id}"
}

# ── Proxmox API objects that already exist (proxmox_iam.tf, proxmox_host.tf) ──
# Each block runs on the first apply and is a no-op afterwards; the read-back must plan NO CHANGES.
# The ids are what the owner commands in README "Proxmox API objects" print.
import {
  to = proxmox_virtual_environment_role.tofu_startup_order
  id = "TofuStartupOrder"
}

import {
  to = proxmox_virtual_environment_user.terraform
  id = "terraform@pve"
}

import {
  to = proxmox_user_token.tofu
  id = "terraform@pve!tofu"
}

# {path}?{user@realm | user@realm!token}?{role}
import {
  for_each = var.pve_acls
  to       = proxmox_acl.managed[each.key]
  id       = "${each.value.path}?${coalesce(each.value.user_id, each.value.token_id)}?${each.value.role_id}"
}

import {
  for_each = var.gpu_pci_mapping == null ? {} : { gpu = var.gpu_pci_mapping.name }
  to       = proxmox_hardware_mapping_pci.gpu[0]
  id       = each.value
}

import {
  to = proxmox_storage_directory.local
  id = "local"
}

import {
  to = proxmox_storage_zfspool.local_zfs
  id = var.datastore_id
}
