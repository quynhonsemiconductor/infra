# pve01 → ai-01: GPU passthrough (ONPREM-PLAN §9.1)

The AI node is a VM on the same host with the RTX 5060 Ti handed through. The
host keeps the AMD iGPU for its console, so nothing on the host needs the
NVIDIA card. Host configuration is not Terraform — it is one reviewed,
idempotent script plus this page.

## What exists (SA read-only check of pve01, 2026-10-31)

| | |
|---|---|
| Proxmox | 9.2.21, kernel 7.0.14-25-pve, ZFS root, systemd-boot |
| GPU | `01:00.0` NVIDIA RTX 5060 Ti `[10de:2d04]` |
| Audio function | `01:00.1` `[10de:22eb]` — same card, passed with it |
| Host driver today | `nouveau` |
| IOMMU | AMD-Vi active; no `iommu=pt` on the cmdline |
| RAM | ~60 GB usable; k3s-01 currently 50 GB, ai-01 will take 20 GB |

## Run it (root, on the host)

```sh
# 1. read-only: what the host looks like now
scripts/owner/pve-gpu-passthrough.sh --check

# 2. write the config (blacklist, vfio ids, iommu=pt, initramfs, PCI mapping)
scripts/owner/pve-gpu-passthrough.sh --apply

# 3. A HOST REBOOT TAKES EVERY VM DOWN — in this order:
qm shutdown 100 --timeout 180     # clean stop of k3s-01
reboot
# after the host is back:
scripts/owner/pve-gpu-passthrough.sh --check    # every line PASS
qm start 100
```

`--apply` is idempotent: each step reads first and only writes what is missing.

## What the script writes, and why

- `/etc/modprobe.d/blacklist-qnsc-gpu.conf` — `nouveau` and the out-of-tree
  `nvidia*` modules never load on the host. A host driver that grabs the card
  makes `vfio-pci` fail to bind.
- `/etc/modprobe.d/vfio-qnsc-gpu.conf` — `options vfio-pci ids=10de:2d04,10de:22eb`:
  bind by PCI id, so the card is claimed before any other driver sees it.
- `iommu=pt` on `/etc/kernel/cmdline` — passthrough devices get identity
  mappings; without it every DMA translation on the host pays for the privilege.
  The original file is backed up beside it.
- `proxmox-boot-tool refresh` — this host boots from the ZFS ESP via
  systemd-boot; `update-initramfs` alone would not update the boot entry.
- PCI mapping `gpu-rtx5060ti` (cluster-level) — `live/onprem-vm` passes
  `mapping = "gpu-rtx5060ti"`, because the bpg provider's raw `id` form is
  incompatible with API-token auth, and the stack never runs as `root@pam`.

## Expected `--check` (after the reboot)

```
01:00.0 VGA compatible controller [0300]: NVIDIA … [10de:2d04]
        Kernel driver in use: vfio-pci
01:00.1 Audio device [0403]: NVIDIA … [10de:22eb]
        Kernel driver in use: vfio-pci
group N: 0000:01:00.0, 0000:01:00.1     ← nothing else in the group
PASS: vfio-pci is bound …
PASS: PCI mapping gpu-rtx5060ti exists
```

If the two functions land in different groups that is fine — both are passed —
but anything else sharing a group with them is not: report it before continuing.

## Rollback

`rm /etc/modprobe.d/*-qnsc-gpu.conf`, remove `iommu=pt` from
`/etc/kernel/cmdline`, `proxmox-boot-tool refresh`, `pvesh delete
/cluster/mapping/pci/gpu-rtx5060ti`, reboot. The card returns to `nouveau`.
