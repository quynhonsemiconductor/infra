# ── k3s-01 as code (ONPREM-PLAN §5.1, runbook §9) ───────────────────────────
#
# The VM was created by hand with `qm clone 9000 100 …` on 2026-10-21. This
# file describes it as it IS; the import block in imports.tf adopts VM 100 and
# `prevent_destroy` makes an accidental recreate impossible. The target state
# of the first plan is NO CHANGES AT ALL for the VM — not "updates in place".
#
# Deliberately NOT managed here (each of these would be a ForceNew or an
# unrequested change to a running node):
#   - clone {}                     every field is ForceNew, and an import never
#                                 sets it — a new site is its own piece of work
#   - initialization / cloud-init  user_data_file_id is ForceNew, so any later
#                                 edit of a snippet would replace the VM
#   - tags, description            the live VM has neither; setting one is a
#                                 diff, and this stack exists to have none
#
# Values are the runbook's §9 commands. The owner's `qm config 100` dump is the
# authority: README "Before the first plan" — reconcile THIS file to it, field
# by field, before applying.

resource "proxmox_virtual_environment_vm" "k3s_01" {
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  # Template 9000 (§7): q35 + OVMF, single-queue virtio-scsi, virtio NIC.
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  # floating = 0 is the provider's way of saying `--balloon 0`.
  memory {
    dedicated = var.vm_memory_mb
    floating  = 0
  }

  efi_disk {
    datastore_id      = var.datastore_id
    type              = "4m"
    pre_enrolled_keys = false
  }

  # OS disk (cloud image, resized to var.os_disk_gb).
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.os_disk_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  # The 1.2 TB local-path disk — formatted whole-disk (no partition table) and
  # mounted by LABEL=k3s-storage, which is how the guest finds it. No serial is
  # set: adding one would rename the device and needs a reboot for nothing.
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi1"
    size         = var.data_disk_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  # `--serial0 socket --vga std`, from the template.
  serial_device {}
  vga {
    type = "std"
  }

  on_boot = true
  startup {
    order      = 1
    down_delay = 180 # NUT: UPS shutdown gives the node three minutes
  }
  started = true

  # This stack must never power-cycle the node as a side effect of an unrelated
  # attribute update. Anything that needs a reboot fails the plan instead.
  reboot_after_update = false

  lifecycle {
    # The VM holds every PVC. A recreate is a data loss event, not a diff;
    # removing this takes a deliberate change to this block, in its own PR.
    prevent_destroy = true

    # Proxmox owns the MAC (rotated on its own); read back, not enforced.
    ignore_changes = [network_device[0].mac_address]
  }
}
