# VM backups to the Proxmox Backup Server co-located on the same host (Ansible role `pbs` installs it, creates the
# datastore, the GC / prune / verify schedules, and the API token this storage logs in with).
#
# Split of duties: PBS owns retention (prune job: 7 daily, 4 weekly, 6 monthly) and verification; PVE only writes.
# So the storage keeps every backup from PVE's side (keep_all) and the job has no prune settings of its own.
#
# CLIENT-SIDE ENCRYPTION (2026-11-06). PVE encrypts each backup before it leaves the guest's backup process, so a
# copy that leaves the machine (the weekly off-site sync, Ansible `pbs`, docs/runbooks/pbs-offsite.md) is
# unreadable without the key.
#
# THE KEY IS NOT IN THIS STACK — deliberately. It is set ONCE, out of band, on pve01:
#   pvesm set pbs-qnsc --encryption-key autogen
# PVE generates the key with `proxmox-backup-client key create --kdf none` semantics and keeps it in
# /etc/pve/priv/storage/pbs-qnsc.enc (root-only). It is NEVER a Terraform input: bpg 0.120 marks
# `encryption_key` sensitive but NOT write-only (checked with `tofu providers schema -json`), so passing it
# through this stack would copy it into the state blob, and no secret belongs there.
#
# What this stack DOES enforce is that encryption is actually on: the read-only `encryption_key_fingerprint`
# must be non-empty, and the precondition below fails the plan when it is not. So an apply cannot register the
# storage unencrypted by accident, and a storage whose key was removed (or replaced without it) is caught here.
#
# LOSING THE KEY MAKES EVERY ENCRYPTED BACKUP UNREADABLE. There is no recovery path: PBS stores opaque chunks
# and the key lives in 1Password, on paper (the `key paperkey` base32 form) and on a USB stick. Every restore
# after the switch needs it (`qmrestore --keyfile <file>`).
#
# Existing unencrypted snapshots stay restorable WITHOUT the key until PBS prunes them (7 daily / 4 weekly /
# 6 monthly). They are also why the off-site sync runs with `--encrypted-only` (Ansible `pbs`): the copy must
# never carry a readable image, and `--encrypted-only` skips those old snapshots instead of publishing them.

variable "pbs_encryption_required" {
  type        = bool
  default     = false
  description = "True once the owner has run the key ceremony (docs/runbooks/pbs-offsite.md §0): the plan then FAILS if the pbs-qnsc storage has no client-side encryption key. False keeps other plans working before the ceremony; it does not turn encryption on or off — PVE owns the key either way."
}

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

  # `encryption_key` is NOT set here: the key lives only in PVE's own config (see the header). It also means
  # this storage can be planned by anyone — no key input, no owner-only environment.

  backups {
    keep_all = true
  }

  lifecycle {
    prevent_destroy = true # the VM backups live in this datastore; removal is a deliberate, separate change
  }
}

# Encryption is ON, or the plan fails — but ONLY once the owner says it must be. `lifecycle.precondition`
# cannot read its own resource, so the check lives on this zero-cost guard resource that depends on it: the
# read-only fingerprint is empty when the storage carries no client-side key, i.e. when the next nightly backup
# would be readable in transit and in the R2 copy. The key itself stays in PVE's /etc/pve/priv (the header
# explains why it is never a TF input).
#
# Default OFF so that every other `live/onprem-vm` plan keeps working before the key ceremony has run; the
# owner flips it on (site.tfvars) in the same apply that first requires encryption. From then on a plan that
# lost the key fails instead of silently backing up in the clear.
resource "terraform_data" "pbs_encryption_required" {
  count = var.pbs_encryption_required ? 1 : 0
  input = proxmox_storage_pbs.pbs_qnsc.encryption_key_fingerprint

  lifecycle {
    precondition {
      condition     = coalesce(proxmox_storage_pbs.pbs_qnsc.encryption_key_fingerprint, "") != ""
      error_message = "pbs-qnsc has no client-side encryption key. On pve01: `pvesm set pbs-qnsc --encryption-key autogen`, then store the key (docs/runbooks/pbs-offsite.md §0) and re-plan. An unencrypted backup must never be synced off-site."
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
