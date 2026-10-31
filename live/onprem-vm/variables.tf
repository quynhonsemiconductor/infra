# ── Proxmox access (owner-side environment only) ────────────────────────────

variable "proxmox_endpoint" {
  type        = string
  sensitive   = true
  description = "Proxmox API endpoint, https://<admin-door host>:8006/ (TF_VAR_proxmox_endpoint). Never committed: an admin-door hostname is Tier 1 in this public repo."

  validation {
    condition     = can(regex("^https://[^/]+:8006/?$", var.proxmox_endpoint))
    error_message = "proxmox_endpoint must be https://<host>:8006/."
  }
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "API token <user@realm>!<tokenid>=<secret> (TF_VAR_proxmox_api_token). Scoped to the VM's pool and VM.* on /vms/100 — never root@pam."
}

# Verification is ON by default. The Proxmox API serves a certificate from the
# PVE CA; trusting that CA is a one-time laptop change, not a per-apply flag:
#
#   curl -fsS https://<admin-door host>:8006/pveca/pve-root-ca.pem -o pve-root-ca.pem
#   sudo security add-trusted-cert -d -r trustRoot \
#     -k /Library/Keychains/System.keychain pve-root-ca.pem
#
# Turning this to true sends the API token to an endpoint nothing verified —
# only for a throwaway host, and never with a token that can create VMs.
variable "proxmox_tls_insecure" {
  type        = bool
  default     = false
  description = "Skip TLS verification of the Proxmox API. Default false: trust the PVE CA in the system store instead."
}

# ── Site values — the ONE file a new site edits is site.tfvars ──────────────
# VM identity and size, network placement, disks. No addresses are defaulted:
# an on-prem address is Tier 1 in this public repo, so the real ones live in
# site.tfvars (git-ignored) only.

variable "proxmox_node" {
  type        = string
  default     = "pve01"
  description = "Proxmox node the VM runs on."
}

variable "vm_id" {
  type        = number
  default     = 100
  description = "Proxmox VM id. 100 is the existing k3s-01 (imported, never recreated)."
}

variable "vm_name" {
  type        = string
  default     = "k3s-01"
  description = "VM name in Proxmox."
}

variable "datastore_id" {
  type        = string
  default     = "local-zfs"
  description = "Datastore for the OS disk, data disk and EFI disk."
}

variable "vm_cores" {
  type        = number
  default     = 28
  description = "vCPU cores (one socket, CPU type host). The host keeps ~8 GB of RAM; do not oversubscribe cores."
}

variable "vm_memory_mb" {
  type = number
  # The live VM has 51200 MB (`qm config 100`), not the 57344 the runbook's
  # `qm set --memory` line implies — the file matched the machine, not the note.
  default     = 51200
  description = "Dedicated memory in MiB (50 GiB, live value). Ballooning stays off (floating = 0)."
}

variable "os_disk_gb" {
  type        = number
  default     = 120
  description = "OS disk size in GiB (scsi0)."
}

variable "data_disk_gb" {
  type        = number
  default     = 1200
  description = "local-path data disk in GiB (scsi1), mounted at /var/lib/rancher/k3s/storage."
}

variable "bridge" {
  type        = string
  default     = "vmbr0"
  description = "Proxmox bridge for net0."
}

variable "vlan_id" {
  type        = number
  default     = null
  description = "VLAN tag on net0. Default null: the live VM has no tag (`qm config 100`: net0 … bridge=vmbr0, no tag), and a tag that is not on the machine is a change that moves the node. Set it in site.tfvars only when the bridge is VLAN-aware and tagged."
}
