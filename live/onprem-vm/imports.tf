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
