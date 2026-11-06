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
  type = number
  # UNCHANGED 28 vCPU: k3s-01 is the control plane and runs every product; it is not
  # resized in the VLSI window (no reboot of the control plane).
  default     = 28
  description = "vCPU cores (one socket, CPU type host). Unchanged: 28."
}

variable "vm_memory_mb" {
  type = number
  # UNCHANGED 24 GiB (24576 MiB). k3s-01's memory requests are ~16.4 GiB with kb prod plus
  # the 2 GiB systemReserved, so shrinking it is not safe. Since the VLSI rollout (2026-11-06)
  # ai-01 is 12 GiB and vlsi-01 16 GiB; the three VMs total 52 GiB of the host's 60.5 GiB,
  # leaving ~8.5 GiB for the host and the ZFS ARC.
  default     = 24576
  description = "Dedicated memory in MiB (24 GiB, unchanged). Ballooning stays off (floating = 0)."
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

variable "ipv4_gateway" {
  type        = string
  description = "Default gateway of the server VLAN (site value, git-ignored tfvars)."
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS resolvers handed to a new VM (site value)."

  validation {
    condition     = length(var.dns_servers) > 0
    error_message = "dns_servers must not be empty."
  }
}

variable "k3s01_ipv4_address" {
  type        = string
  description = "Static address of k3s-01 in CIDR form, as its cloud-init carries it. Site value, git-ignored tfvars only."
  validation {
    condition     = can(cidrhost(var.k3s01_ipv4_address, 0))
    error_message = "k3s01_ipv4_address must be an address in CIDR notation."
  }
}

variable "proxmox_ssh_address" {
  type        = string
  description = "Address the provider SSHes to (as root, via the owner's ssh-agent) to upload snippets. Site value, git-ignored tfvars only."
}

# ── Proxmox API objects (proxmox_iam.tf, proxmox_host.tf) ───────────────────

variable "proxmox_token_privilege_separation" {
  type        = bool
  default     = true
  description = "privsep of the `tofu` API token (`pveum user token list terraform@pve`). true = the token has its own ACLs (pve_acls entries with token_id); false = it inherits the user's."
}

variable "pve_acls" {
  type = map(object({
    path      = string
    role_id   = string
    user_id   = optional(string)
    token_id  = optional(string)
    propagate = optional(bool, true)
  }))
  default     = {}
  description = "ACL entries of terraform@pve / its token, keyed by any stable label. Exactly one of user_id (`terraform@pve`) or token_id (`terraform@pve!tofu`) per entry. Copy them from `pveum acl list` into the git-ignored site.tfvars."

  validation {
    condition     = alltrue([for k, a in var.pve_acls : (a.user_id == null) != (a.token_id == null)])
    error_message = "each pve_acls entry needs exactly one of user_id or token_id."
  }
}

variable "gpu_pci_mapping" {
  type = object({
    name    = string
    comment = optional(string)
    map = list(object({
      id           = string
      node         = string
      path         = string
      iommu_group  = optional(number)
      subsystem_id = optional(string)
      comment      = optional(string)
    }))
  })
  default     = null
  description = "The cluster PCI mapping ai-01 passes through (null = this site has none). Site values (PCI paths, IOMMU groups, subsystem ids): git-ignored site.tfvars; `scripts/owner/pve-gpu-passthrough.sh --check` prints the snippet."
}

variable "zfs_pool" {
  type        = string
  default     = "rpool/data"
  description = "ZFS dataset behind the `local-zfs` storage (the Proxmox installer's default)."
}
