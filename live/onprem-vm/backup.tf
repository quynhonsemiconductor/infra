# VM backups to the Proxmox Backup Server co-located on the same host (Ansible role `pbs` installs it, creates the
# datastore, the GC / prune / verify schedules, and the API token this storage logs in with).
#
# Split of duties: PBS owns retention (prune job: 7 daily, 4 weekly, 6 monthly) and verification; PVE only writes.
# So the storage keeps every backup from PVE's side (keep_all) and the job has no prune settings of its own.
#
# CLIENT-SIDE ENCRYPTION (2026-11-06). The backup is encrypted by PVE before it leaves the guest's host process,
# so a copy that leaves the machine (the weekly off-site sync, Ansible `pbs`, docs/runbooks/pbs-offsite.md) is
# unreadable without the key. The key is created ONCE by the owner with
# `proxmox-backup-client key create --kdf none` (PVE only supports keys with no KDF), kept in 1Password, on
# paper (its `key paperkey` base32 form) and on a USB stick — and it is passed to this stack through
# TF_VAR_pbs_encryption_key from 1Password, never committed.
#
# LOSING THE KEY MAKES EVERY ENCRYPTED BACKUP UNREADABLE. There is no recovery path without it: PBS stores
# opaque chunks and the key lives only in those three places. Restoring needs the key file too
# (`qmrestore --keyfile <file>`), and it is required for every restore AFTER the switch, including the routine
# Tier A/B drills.
#
# The switch is one apply: PVE writes the key to /etc/pve/priv/storage/pbs-qnsc.enc and encrypts every NEW
# backup. Existing unencrypted snapshots stay restorable without the key until PBS prunes them (the prune job
# keeps 7 daily / 4 weekly / 6 monthly, so the last unencrypted snapshot ages out on its own). Run
# docs/runbooks/pbs-offsite.md §1 before this apply: the key must already be in 1Password, on paper and on the
# USB stick, or this storage becomes a pile of noise.

variable "pbs_server" {
  type        = string
  default     = "127.0.0.1"
  description = "Address PVE uses to reach PBS. PBS runs on the same host, so loopback; change it only if PBS moves."
}

variable "pbs_encryption_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "CLIENT-SIDE encryption key for this storage: the CONTENTS of the key file the owner created with `proxmox-backup-client key create --kdf none`. From 1Password, never committed: TF_VAR_pbs_encryption_key=\"$(op read ...)\". Empty = encryption OFF (the pre-2026-11-06 behaviour), which the precondition below refuses once the off-site sync exists."

  validation {
    condition     = var.pbs_encryption_key == "" || length(var.pbs_encryption_key) >= 200
    error_message = "pbs_encryption_key must be the whole key FILE content (a PEM/AES blob of a few hundred bytes), not a password or a fingerprint. Generate it with `proxmox-backup-client key create --kdf none <file>`."
  }
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

  # Client-side encryption (see the header). The provider marks this write-only where the Terraform version
  # supports it (1.11+), so the key does not have to land in state; `encryption_key_fingerprint` (read-only)
  # is what the plan shows instead. Empty leaves the storage unencrypted, which the precondition below forbids.
  encryption_key = var.pbs_encryption_key

  backups {
    keep_all = true
  }

  lifecycle {
    precondition {
      condition     = length(var.pbs_encryption_key) > 0
      error_message = "pbs_encryption_key is empty. An unencrypted backup must not be copied off-site (Ansible pbs, qnsc-pbs-offsite): set TF_VAR_pbs_encryption_key from 1Password before applying, or the off-site sync would publish readable VM images."
    }
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
