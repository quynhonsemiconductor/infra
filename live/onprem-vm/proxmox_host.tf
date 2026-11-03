# ── Proxmox API objects of the host: PCI mapping, storage ────────────────────
#
# IaC covers what the Proxmox API owns. Everything below the API (kernel cmdline, vfio and
# nouveau modprobe files, initramfs, ZFS ARC limit, the host's /etc files, the template build)
# is the idempotent owner scripts in scripts/owner/ (README "Where IaC stops").
#
# All imported, none created: see imports.tf.

# ── The GPU's PCI mapping (what ai-01's hostpci0 references) ─────────────────
# An API token cannot pass a raw hostpci id, only a mapping; Proxmox validates a mapping against the
# hardware at VM start, so every entry carries iommu_group and subsystem_id as the host reports them.
# Those values are the site's (git-ignored tfvars); `scripts/owner/pve-gpu-passthrough.sh --check`
# prints a ready-made snippet from sysfs.
resource "proxmox_hardware_mapping_pci" "gpu" {
  count = var.gpu_pci_mapping == null ? 0 : 1

  name    = var.gpu_pci_mapping.name
  comment = var.gpu_pci_mapping.comment
  map     = var.gpu_pci_mapping.map

  lifecycle {
    prevent_destroy = true
  }
}

# ── Storage definitions the stack relies on ──────────────────────────────────
# `local` holds ISOs, templates, backups and the cloud-init snippets of ai-01 (hence `snippets`,
# which scripts/owner/pve-gpu-passthrough.sh enables); `local-zfs` is where every VM disk lives. Both
# are the installer's definitions; the values below are the live host's (pve01, checked 2026-11-03), not
# the provider defaults, so the import plans no change. `nodes` is set to the empty set explicitly: the
# live storages carry no `nodes` key (= every node), and leaving it unset makes the provider plan it as
# known-after-apply. The PBS storage (`pbs-qnsc`) and the backup jobs are NOT here: backup.tf is their
# only owner (one resource, one source of truth).
resource "proxmox_storage_directory" "local" {
  id      = "local"
  path    = "/var/lib/vz"
  content = ["backup", "import", "iso", "snippets", "vztmpl"]
  nodes   = []
  shared  = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_storage_zfspool" "local_zfs" {
  id             = var.datastore_id
  zfs_pool       = var.zfs_pool
  content        = ["images", "rootdir"]
  blocksize      = "16k"
  nodes          = []
  thin_provision = true

  lifecycle {
    prevent_destroy = true
  }
}
