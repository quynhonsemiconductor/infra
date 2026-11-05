# ── vlsi-01 — the VLSI / EDA workspace node (Phase 3) ───────────────────────
#
# A third k3s agent for the per-user workspaces (JupyterLab + EDA tools): 4 vCPU,
# 4 GiB, no GPU. It joins the existing cluster (lane D's Ansible role `k3s-agent`,
# docs/runbooks/phase3-window.md step 5) with the label `qnsc.vn/pool=vlsi` and the
# taint `qnsc.vn/pool=vlsi:NoSchedule`, so only workloads that tolerate it land there.
# Small on purpose: the VLSI team has not started, so the RAM and cores sit with ai-01
# and k3s-01 until it does; grow both when the workspaces get real users (a plain
# size increase, same window/stop-start rules as the other VMs).
#
# ── PRODUCTION WINS UNDER CONTENTION ────────────────────────────────────────
# Compute jobs are CPU-bound and the host is shared with k3s-01 (rova prod, pg-rova).
# `cpu.units` is the Proxmox CPU weight (cgroup `cpu.weight` on a v2 host, default 100;
# the provider documents 1024 for a v1 host): k3s-01 and ai-01 keep the default, vlsi-01
# gets 25, so when the host runs out of CPU the scheduler hands prod about four times
# the share per VM. The weight only matters under contention; an idle host lets vlsi-01
# use every core it has. Check the default on the host before applying:
#   ssh root@<admin-door host> 'stat -fc %T /sys/fs/cgroup; qm config 100 | grep -i cpuunits'
#   (cgroup2fs and no cpuunits line = default 100, so 25 is lower; on cgroup v1 the default
#   is 1024 and 25 is lower still.)
#
# Disk: scsi0 40 GiB (OS), scsi1 `vlsi01_data_disk_gb` for the workspaces' /home PVCs
# (local-path on this node), same datastore as the others (local-zfs). 300 GiB covers
# ten 20 GiB homes plus tool images and scratch; check `zpool list` free space first,
# the pool also holds k3s-01's 1.2 TB and ai-01's 340 GiB.

variable "vlsi01_vm_id" {
  type        = number
  default     = 102
  description = "Proxmox id for vlsi-01."
}

variable "vlsi01_vm_name" {
  type        = string
  default     = "vlsi-01"
  description = "VM name and guest hostname."
}

variable "vlsi01_cores" {
  type = number
  # 4 vCPU, down from 12: the node used ~0.7 GiB and no meaningful CPU before the team starts.
  default     = 4
  description = "vCPUs. Re-balance target: 4 (grow when the VLSI team starts; validation allows up to 16)."

  validation {
    condition     = var.vlsi01_cores >= 4 && var.vlsi01_cores <= 16
    error_message = "vlsi01_cores must be within 4-16."
  }
}

variable "vlsi01_memory_mb" {
  type = number
  # 4 GiB (4096 MiB), down from 20 GiB: the workspaces have no users yet, and ai-01 takes the
  # spare. With k3s-01 24 + ai-01 28 + vlsi-01 4 = 56 GiB the host keeps ~6 GiB for itself and
  # the ZFS ARC.
  default     = 4096
  description = "4 GiB after the re-balance (was 20 GiB), ballooning off (like the other nodes: predictable, and k3s counts on the memory it sees). Stop/start applies it."
}

variable "vlsi01_cpu_units" {
  type        = number
  default     = 25
  description = "Proxmox CPU weight, LOWER than k3s-01's so production wins under contention (see the header of this file)."

  validation {
    condition     = var.vlsi01_cpu_units >= 1 && var.vlsi01_cpu_units <= 100
    error_message = "vlsi01_cpu_units must stay below the default weight (100 on cgroup v2) so that k3s-01 wins."
  }
}

variable "vlsi01_data_disk_gb" {
  type        = number
  default     = 300
  description = "Workspace /home disk (local-zfs). Ten 20 GiB homes plus images and scratch; grow it later by a plain size increase (ZFS zvols grow online)."
}

variable "vlsi01_ipv4_address" {
  type        = string
  description = "Static address of vlsi-01 in CIDR form. Site value, git-ignored tfvars only (next free address after ai-01)."

  validation {
    condition     = can(cidrhost(var.vlsi01_ipv4_address, 0))
    error_message = "vlsi01_ipv4_address must be an address in CIDR notation."
  }
}

resource "proxmox_virtual_environment_vm" "vlsi_01" {
  name        = var.vlsi01_vm_name
  description = "VLSI / EDA workspace node (managed by infra/live/onprem-vm)"
  node_name   = var.proxmox_node
  vm_id       = var.vlsi01_vm_id

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
    cores = var.vlsi01_cores
    type  = "host"
    units = var.vlsi01_cpu_units
  }

  memory {
    dedicated = var.vlsi01_memory_mb
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
    size         = var.vlsi01_data_disk_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  # No hostpci: this node has no GPU.

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  # Cloud-init like k3s-01's: user `qnsc`, the operator keys, a static address. The guest
  # hostname follows the VM name. No user-data snippet (user_data_file_id is ForceNew, and
  # the template already carries the guest agent).
  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"
    upgrade      = true
    dns {
      servers = var.dns_servers
    }
    ip_config {
      ipv4 {
        address = var.vlsi01_ipv4_address
        gateway = var.ipv4_gateway
      }
    }
    user_account {
      username = "qnsc"
      keys     = var.ssh_public_keys
    }
  }

  on_boot = true
  startup {
    order      = 3 # after k3s-01 (1, the server) and ai-01 (2); it joins as an agent
    down_delay = 60
  }
  started = true

  reboot_after_update = false

  lifecycle {
    # It holds the workspaces' /home volumes; removing this takes a deliberate change in its own PR.
    prevent_destroy = true
    ignore_changes  = [network_device[0].mac_address]
  }
}

output "vlsi01_vm_id" {
  description = "Proxmox id of vlsi-01."
  value       = proxmox_virtual_environment_vm.vlsi_01.vm_id
}
