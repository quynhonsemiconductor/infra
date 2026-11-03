# VM backups to the Proxmox Backup Server co-located on the same host (Ansible role `pbs` installs it, creates the
# datastore, the GC / prune / verify schedules, and the API token this storage logs in with).
#
# Split of duties: PBS owns retention (prune job: 7 daily, 4 weekly, 6 monthly) and verification; PVE only writes.
# So the storage keeps every backup from PVE's side (keep_all) and the job has no prune settings of its own.
#
# No client-side encryption for now: the datastore is on the same machine as the VMs, behind the same root, so a key
# protects nothing there and losing it would make every backup unreadable. Turn it on together with an off-site
# copy (PBS sync / remote), with the key created once and kept in 1Password.

variable "pbs_server" {
  type        = string
  default     = "127.0.0.1"
  description = "Address PVE uses to reach PBS. PBS runs on the same host, so loopback; change it only if PBS moves."
}

variable "pbs_datastore" {
  type        = string
  default     = "qnsc"
  description = "PBS datastore name (Ansible pbs_datastore_name)."
}

variable "pbs_token_id" {
  type        = string
  default     = "backup@pbs!pve"
  description = "PBS API token id that PVE logs in with (Ansible pbs_pve_user ! pbs_pve_token_name)."
}

# The provider has no write-only password input, so this secret lands in the state: the second documented exception
# after the Entra IdP secret in live/edge (docs/runbooks/host-config-inventory.md). Its reach is small: the token only
# holds DatastoreBackup on this one datastore, and the state backend is private and encrypted at rest.
variable "pbs_token_secret" {
  type        = string
  sensitive   = true
  description = "Secret of pbs_token_id. From the environment only: TF_VAR_pbs_token_secret=\"$(op read ...)\" (1Password item \"PBS - pve backup - API token\")."
}

variable "pbs_fingerprint" {
  type        = string
  description = "SHA-256 fingerprint of the PBS certificate, as the Ansible pbs role prints it (site tfvars)."
  validation {
    condition     = can(regex("^([0-9a-fA-F]{2}:){31}[0-9a-fA-F]{2}$", var.pbs_fingerprint))
    error_message = "pbs_fingerprint must be a SHA-256 fingerprint (32 colon-separated hex bytes)."
  }
}

variable "backup_schedule" {
  type        = string
  default     = "*-*-* 01:30"
  description = "When the nightly VM backup runs (systemd calendar event, host time). Before the PBS GC at 03:00."
}

resource "proxmox_storage_pbs" "pbs_qnsc" {
  id        = "pbs-qnsc"
  nodes     = [var.proxmox_node]
  server    = var.pbs_server
  datastore = var.pbs_datastore

  username    = var.pbs_token_id
  password    = var.pbs_token_secret
  fingerprint = var.pbs_fingerprint

  content = ["backup"]

  backups {
    keep_all = true
  }
}

resource "proxmox_backup_job" "nightly" {
  id       = "qnsc-nightly"
  comment  = "Nightly VM backup to PBS (infra live/onprem-vm). Retention lives in PBS."
  schedule = var.backup_schedule
  storage  = proxmox_storage_pbs.pbs_qnsc.id
  node     = var.proxmox_node
  vmid = [
    tostring(proxmox_virtual_environment_vm.k3s_01.vm_id),
    tostring(proxmox_virtual_environment_vm.ai_01.vm_id),
    tostring(proxmox_virtual_environment_vm.vlsi_01.vm_id),
  ]

  # snapshot = live backup through QEMU; the guest agent freezes the filesystems for a consistent image.
  mode              = "snapshot"
  enabled           = true
  repeat_missed     = true
  notification_mode = "notification-system"
}
