# ── ai-01 — the GPU agent node (ONPREM-PLAN §9.1) ───────────────────────────
#
# One cluster, two nodes: k3s-01 keeps platform, data and products and never
# loads an NVIDIA driver; ai-01 takes the passed-through RTX 5060 Ti and runs
# only the `ai` namespace (taint below). An AI OOM or a driver upgrade restarts
# this VM and nothing else.
#
# A host reboot is required before the first apply of this file: the card must
# be bound to vfio-pci and the PCI mapping must exist
# (docs/onprem-gpu-passthrough.md, scripts/owner/pve-gpu-passthrough.sh).
#
# New VM, so cloud-init applies here (unlike VM 100, which is imported and left
# alone): the guest hostname, the operator's keys and a static address on the
# server VLAN.

variable "ai01_vm_id" {
  type        = number
  default     = 101
  description = "Proxmox id for ai-01."
}

variable "ai01_vm_name" {
  type        = string
  default     = "ai-01"
  description = "VM name and guest hostname."
}

variable "ai01_cores" {
  type = number
  # 8 vCPU (VLSI rollout, 2026-11-06): inference burst is short and the GPU does the work; the
  # 4 vCPUs go to vlsi-01, where every RTL build and simulation runs. The three VMs total
  # 48 vCPUs (28 + 8 + 12) on 32 host threads; vCPUs are time-sliced, so this is
  # oversubscription, not a hard limit.
  default     = 8
  description = "vCPUs. VLSI rollout: 8 (k3s-01 28, vlsi-01 12)."

  validation {
    condition     = var.ai01_cores >= 4 && var.ai01_cores <= 12
    error_message = "ai01_cores must be within 4-12 (the validated 12-vCPU ceiling)."
  }
}

variable "ai01_memory_mb" {
  type = number
  # 12 GiB (12288 MiB). The measured peak over 7 days is 4.0 GB, and the e5 and reranker
  # models live in VRAM, not RAM; GPU passthrough pins the whole allocation (floating = 0),
  # so 12 GiB is 3x the peak. 24 (k3s-01) + 12 (ai-01) + 16 (vlsi-01) = 52 GiB of the host's
  # 60.5, leaving ~8.5 GiB for the host and the ZFS ARC — the same total as before the
  # VLSI node, so no new pressure on the host.
  default     = 12288
  description = "12 GiB (the measured peak is 4.0 GB; models sit in VRAM). Ballooning OFF is required for passthrough (the provider sets floating = 0); a stop/start applies it."
}

variable "ai01_data_disk_gb" {
  type        = number
  default     = 300
  description = "Model-cache disk, same pool as k3s-01 (local-zfs)."
}

variable "ai01_ipv4_address" {
  type        = string
  description = "Static address of ai-01 in CIDR form. Site value, git-ignored tfvars only."

  validation {
    condition     = can(cidrhost(var.ai01_ipv4_address, 0))
    error_message = "ai01_ipv4_address must be an address in CIDR notation."
  }
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "Operator public keys for the ai-01 cloud-init user."

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "ssh_public_keys must not be empty."
  }
}

locals {
  ai01_user_data = <<-YAML
    #cloud-config
    hostname: ${var.ai01_vm_name}
    manage_etc_hosts: true
    timezone: Asia/Ho_Chi_Minh
    ssh_authorized_keys:
    ${join("\n", [for k in var.ssh_public_keys : "  - ${k}"])}
    package_update: true
    packages:
      - qemu-guest-agent
      - chrony
  YAML
}

resource "proxmox_virtual_environment_file" "ai01_user_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = local.ai01_user_data
    file_name = "qnsc-${var.ai01_vm_name}-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "ai_01" {
  name        = var.ai01_vm_name
  description = "GPU agent node for the ai namespace (managed by infra/live/onprem-vm)"
  node_name   = var.proxmox_node
  vm_id       = var.ai01_vm_id

  clone {
    vm_id     = 9000
    node_name = var.proxmox_node
    full      = true
  }

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
    cores = var.ai01_cores
    type  = "host"
  }

  # Passthrough needs a pinned, non-ballooned allocation.
  memory {
    dedicated = var.ai01_memory_mb
    floating  = 0
  }

  efi_disk {
    datastore_id      = var.datastore_id
    type              = "4m"
    pre_enrolled_keys = false
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = 40
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi1"
    size         = var.ai01_data_disk_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  # The RTX 5060 Ti and its audio function, as one mapping. `mapping` and not
  # `id`: the raw form needs root@pam and this stack runs on an API token
  # (scripts/owner/pve-gpu-passthrough.sh creates the mapping).
  hostpci {
    device  = "hostpci0"
    mapping = "gpu-rtx5060ti"
    pcie    = true
  }

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"
    ip_config {
      ipv4 {
        address = var.ai01_ipv4_address
        gateway = var.ipv4_gateway
      }
    }
    dns {
      servers = var.dns_servers
    }
    user_data_file_id = proxmox_virtual_environment_file.ai01_user_data.id
  }

  on_boot = true
  startup {
    order      = 2 # k3s-01 (order 1) is the server; the agent joins it
    down_delay = 120
  }
  started = true

  reboot_after_update = false

  lifecycle {
    prevent_destroy = true
  }
}

output "ai01_vm_id" {
  description = "Proxmox id of ai-01 (the join script's documentation value)."
  value       = proxmox_virtual_environment_vm.ai_01.vm_id
}
