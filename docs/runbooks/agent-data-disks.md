# Agent data disks: mount the 300 GiB disk and move the TEI model cache off root

`ai-01` and `vlsi-01` each have a 300 GiB `scsi1` disk that OpenTofu allocates and nothing used:
local-path volumes (the TEI model cache, the VLSI workspaces' `/home`) were landing on the 40 GiB
root, where DiskPressure evicts clamd/TEI. The Ansible role `k3s_data_disk` mounts the disk at
`/var/lib/rancher/k3s/storage` (label `k3s-storage`), the same shape as k3s-01.

Run from `ansible/`, with `op run` for the join token, in a maintenance window: the move stops
`k3s-agent` on the node, so its pods go down for the duration.

## Safety rules the role enforces

- It is off unless `-e k3s_data_disk_enabled=true`; a full playbook run never touches a disk.
- It accepts only a `/dev/disk/by-id/` path, refuses the root disk, and refuses a device outside the
  250-400 GB class — the wrong device is data loss.
- It **never formats** without `-e k3s_data_disk_format=true`, and only a device with no filesystem
  type, no partition table and no `wipefs` signature at all.
- It refuses to mount over a non-empty `/var/lib/rancher/k3s/storage` unless
  `-e k3s_data_disk_allow_move=true`. Mounting over that directory would hide every existing PV.
- With the move opt-in it stops `k3s-agent`, asserts the unit is stopped and no process holds the
  volume path (`fuser -m`), copies with `rsync -aHAX --numeric-ids`, proves a second dry run has no
  differences, mounts, and **always** starts the agent again (a `block`/`always`, even on failure).
- fstab uses `defaults,noatime,nofail,x-systemd.device-timeout=30`.

## ai-01 — move the TEI model cache (do this first)

The cache PV (`tei-e5-model-cache`) already exists under the root. The copy keeps its directory
name, so the existing PersistentVolume and the pod's mount are unchanged; nothing re-downloads.

First find the disk's stable id **inside ai-01** (never pass `/dev/sdb`):

```sh
ls -l /dev/disk/by-id/ | grep -i virtio     # pick the 300G scsi1, not the 40G scsi0
```
```sh
cd ansible
op run --env-file=<local template> -- \
  ansible-playbook k3s-agent-gpu.yml --tags k3s_data_disk --check --diff \
  -e k3s_data_disk_enabled=true -e k3s_data_disk_device=/dev/disk/by-id/<id> \
  -e k3s_data_disk_format=true -e k3s_data_disk_allow_move=true
# Review: mkfs only on a truly blank disk, the copy, the fstab line, the mount.

op run --env-file=<local template> -- \
  ansible-playbook k3s-agent-gpu.yml --tags k3s_data_disk \
  -e k3s_data_disk_enabled=true -e k3s_data_disk_device=/dev/disk/by-id/<id> \
  -e k3s_data_disk_format=true -e k3s_data_disk_allow_move=true
```

Verify on ai-01:

```sh
findmnt --mountpoint /var/lib/rancher/k3s/storage     # SOURCE /dev/sdb
df -h /var/lib/rancher/k3s/storage                     # ~300G, not 40G
sudo du -sh /var/lib/rancher/k3s/storage/pvc-*         # the model cache is here
kubectl -n ai get pods                                 # tei-e5 Running and Ready, clamd Running
kubectl -n ai logs deploy/tei-e5 --tail=20             # no download, it starts offline from the cache
```

The old copy is now hidden by the mount point and still occupies root. It is a few GB; delete it only
in a later window by unmounting, removing the stale directory and mounting again, or leave it.

If the role stops with an error after `k3s-agent` was stopped, the old data is still intact and the
final mount has not happened: run `sudo systemctl start k3s-agent` on the node to restore service,
then read the failing task (it names the file or the copy check) before re-running.

## vlsi-01 — mount before the first workspace

The disk has no filesystem and nothing at the mount path, so this is the simple path:

```sh
ls -l /dev/disk/by-id/ | grep -i virtio     # on vlsi-01; pick the 300G scsi1
cd ansible
op run --env-file=<local template> -- \
  ansible-playbook k3s-agent.yml --tags k3s_data_disk --check --diff \
  -e k3s_data_disk_enabled=true -e k3s_data_disk_device=/dev/disk/by-id/<id> \
  -e k3s_data_disk_format=true
op run --env-file=<local template> -- \
  ansible-playbook k3s-agent.yml --tags k3s_data_disk \
  -e k3s_data_disk_enabled=true -e k3s_data_disk_device=/dev/disk/by-id/<id> \
  -e k3s_data_disk_format=true
```

Then a normal agent run to prove no drift: `ansible-playbook k3s-agent.yml --check --diff`.

## Why this is not in OpenTofu

The disk is an API object (OpenTofu owns it). Formatting, the label and the fstab line are inside
the guest, which is the Ansible layer (`docs/runbooks/host-config-inventory.md`). Ansible never
creates or destroys a disk; it only uses the one OpenTofu already made, and only when told to.
