# live/onprem-vm

The Proxmox VM `k3s-01` (VM 100) as code. Built by hand on 2026-10-21; this
stack **imports** the existing VM and describes it as it is. Its target is a
plan that reports **no changes** for VM 100 — anything else is this file
disagreeing with the live machine.

Owner-applied only (`NOT_PLANNABLE` in `.github/workflows/infra-plan.yml`): CI
holds no Proxmox token, and the API endpoint is the admin door.

## Owns

- `proxmox_virtual_environment_vm.k3s_01` — 28 vCPU, 24 GiB since Phase 3 (balloon off),
  q35 + OVMF, virtio-scsi-single, scsi0 120 G, scsi1 1200 G, net0 on the
  server VLAN, serial0 socket, VGA std. `prevent_destroy` is set: the VM holds
  every PVC. `reboot_after_update = false` — this stack never power-cycles the
  node as a side effect.
- Proxmox API objects of the host, imported (`proxmox_iam.tf`, `proxmox_host.tf`): the user
  `terraform@pve`, the API token `tofu`, the role `TofuStartupOrder` (Sys.Modify), the ACL entries, the PCI
  mapping `gpu-rtx5060ti`, and the storages `local` and `local-zfs`. Provider
  `bpg/proxmox ~> 0.120`. See "Proxmox API objects" and "Where IaC stops" below.
- `proxmox_storage_pbs.pbs_qnsc` + `proxmox_backup_job.nightly` (`backup.tf`) — PVE side of the
  co-located Proxmox Backup Server: storage `pbs-qnsc` (token login, pinned certificate fingerprint)
  and the nightly snapshot-mode backup of VMs 100, 101 and 102. Retention, GC and verify are PBS jobs
  (Ansible role `pbs`). Needs `TF_VAR_pbs_token_secret` from 1Password and `pbs_fingerprint` in
  site.tfvars:
  ```sh
  export TF_VAR_pbs_token_secret="$(op read 'op://QNSC/<item-id>/secret')"
  ```
  `backup.tf` is the **only** owner of the PBS storage and of every backup job: do not add a
  `proxmox_backup_job` anywhere else.

## Not managed, on purpose

- `clone {}` — every field is ForceNew, and an import never sets it. Creating a
  new site from template 9000 is its own piece of work.
- `initialization.user_data_file_id` — ForceNew, so a snippet would **replace** the
  VM. The rest of k3s-01's cloud-init (ide2, IP, DNS, user, keys) IS described, as it
  stands on the live VM.
- Tags, description — the live VM has neither, and setting one is a diff.
- Anything inside the guest (disks, filesystems, k3s install, the kubelet
  drop-in). Those are the node's own state. The k3s config and version pin have
  ONE source: the Ansible `k3s_server` role (see below).

## Before the first plan — the live VM is the authority

Dump the live config and reconcile `vm.tf` against it, field by field
(`machine`, `bios`, `scsihw`, `cpu`, `memory`, `balloon`, `efidisk0`, `scsi0`,
`scsi1`, `net0` + tag, `serial0`, `vga`, `agent`, `onboot`, `startup`). Paste
the dump to the SA, not into the repo — it carries the site's addresses.

```sh
ssh root@<admin-door host> 'qm config 100'
```

Two values cannot be guessed and are REQUIRED variables: the VLAN tag
(`site.tfvars`) and the Proxmox endpoint (`TF_VAR_proxmox_endpoint`).

Trust the PVE CA instead of disabling verification (the default stays
`proxmox_tls_insecure = false`):

```sh
curl -fsS https://<admin-door host>:8006/pveca/pve-root-ca.pem -o pve-root-ca.pem
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain pve-root-ca.pem
```

## First apply

```sh
cd live/onprem-vm
export ARM_SUBSCRIPTION_ID=<subscription-id>
export TF_VAR_proxmox_endpoint=https://<admin-door host>:8006/
export TF_VAR_proxmox_api_token="$(op read 'op://QNSC/<item-id>/<field>')"
cp site.tfvars.example site.tfvars && chmod 600 site.tfvars   # then set vlan_id
tofu init
tofu plan -out=tfplan
```

**Go/no-go:** `1 to import, 0 to add, 0 to change, 0 to destroy`, and on VM 100
**no attribute line at all** — not "will be updated in place", not
`# forces replacement`. If the plan shows anything, reconcile `vm.tf` to the
`qm config 100` dump in a reviewed commit; do not apply and let the provider
"correct" the live VM.

```sh
tofu apply tfplan
tofu plan        # must be: No changes.
```

## The k3s config on the node

There is ONE source: the Ansible `k3s_server` role (`ansible/roles/k3s_server/templates/config.yaml.j2`,
the `k3s_version` pin in `ansible/group_vars/k3s.yml`, and the `kubelet` role's drop-in). This stack
no longer carries a copy under `files/`: a second copy without the ESO issuer lines made a rebuild
silently lose workload identity. Run from `ansible/`:

```sh
ansible-playbook k3s-server.yml --check --diff
ansible-playbook k3s-server.yml          # writes config; reports that a restart is needed
ansible-playbook k3s-server.yml -e k3s_server_allow_restart=true -e kubelet_allow_restart=true
```

Set `k3s_server_oidc_issuer` (and its `_old` second issuer) in the git-ignored local inventory; the
value must equal `live/onprem-oidc` and `live/identity` `eso_oidc_issuer`.

## Proxmox API objects (import, then No changes)

Everything here already exists on pve01, made by hand. `imports.tf` carries the `import {}` blocks; they run
on the first apply, nothing is created, and the target is a plan that reports **No changes** for them. A diff
means a `.tf` value disagrees with the host: change the file (or your `site.tfvars`), never the host.

**Site values stay local.** The ACL entries and the PCI mapping details are variables
(`pve_acls`, `gpu_pci_mapping`, default empty/null); put the real ones in the git-ignored
`site.tfvars` (the SA's copy is `sa-local/onprem-vm.site.tfvars`). `site.tfvars.example` shows the shapes.

Read the facts on pve01 (owner, as root; read-only, nothing here prints a secret):

```sh
# 1. identity: the user, the token (look at `privsep`), the role, the ACLs
pveum user list --output-format json | jq '.[] | select(.userid=="terraform@pve")'
pveum user token list terraform@pve --output-format json            # tokenid "tofu", privsep 0|1
pveum role list --output-format json | jq '.[] | select(.roleid=="TofuStartupOrder")'
pveum acl list --output-format json | jq '.[] | select(.ugid | startswith("terraform@pve"))'
#   one pve_acls entry per row: path, roleid -> role_id, propagate; ugid `terraform@pve` -> user_id,
#   `terraform@pve!tofu` -> token_id

# 2. the PCI mapping (iommugroup and subsystem-id are what Proxmox validates at VM start)
pvesh get /cluster/mapping/pci/gpu-rtx5060ti --output-format json
scripts/owner/pve-gpu-passthrough.sh --check        # also prints a gpu_pci_mapping snippet from sysfs

# 3. storages
pvesh get /storage --output-format json | jq '.[] | {storage, type, path, pool, content, nodes}'
pvesh get /storage/local --output-format json
pvesh get /storage/local-zfs --output-format json
```

The import ids the blocks use (so you can also run them by hand with `tofu import`):

| Resource | Import id |
|---|---|
| `proxmox_virtual_environment_role.tofu_startup_order` | `TofuStartupOrder` |
| `proxmox_virtual_environment_user.terraform` | `terraform@pve` |
| `proxmox_user_token.tofu` | `terraform@pve!tofu` |
| `proxmox_acl.managed["<key>"]` | `<path>?<terraform@pve or terraform@pve!tofu>?<role>` |
| `proxmox_hardware_mapping_pci.gpu[0]` | `gpu-rtx5060ti` |
| `proxmox_storage_directory.local` / `proxmox_storage_zfspool.local_zfs` | `local` / `local-zfs` |

Then, as for VM 100: `tofu plan` must say **No changes** for all of them before any apply. Reconcile field
by field if not (`comment`, `email`, `enabled` of the user; the storage `content` and `thin_provision`):
the host is the authority. Four things to know:

- **The token secret is not in IaC.** In provider 0.120.0 `proxmox_user_token` exposes `value` only as a
  `computed` + `sensitive` attribute, populated on create and never on read or import: an import leaves it null,
  so nothing is rotated and no secret enters state. That is why the token IS managed here. This stack
  authenticates with that token, so every one of these resources has `prevent_destroy`, and the token must
  never be recreated from here.
- **The user has no `password`**, for the same reason (an import cannot read it back; setting one is a write).
- **The PBS storage and every backup job belong to `backup.tf`**, not to this section: they are created (or
  adopted) there, and `backup.tf` is their single owner.
- **`proxmox_acl` / `proxmox_hardware_mapping_pci` / the directory and zfspool storages use the provider's
  newer `proxmox_*` resource names** (the legacy `proxmox_virtual_environment_*` twins exist for some); the user
  and role, and the VMs, only exist under the legacy names.

## Where IaC stops

| Layer | Owner | Where |
|---|---|---|
| Proxmox **API objects**: VMs, users, token, role, ACLs, PCI mapping, storages | OpenTofu | this stack |
| Host **OS**: kernel cmdline (`iommu=pt`), vfio / nouveau modprobe files, initramfs, ZFS ARC limit, `snippets` on `local`, UPS/NUT, PBS install | idempotent owner scripts and runbooks run as root on pve01 | `scripts/owner/pve-gpu-passthrough.sh`, the server-setup runbook |
| The VM **template** 9000 (an Ubuntu cloud image turned into a template) | idempotent owner script | `scripts/owner/pve-template-9000.sh` |
| Inside the VMs: k3s install and config, kubelet drop-in, drivers | Ansible `k3s_server` / `k3s_agent*` / `kubelet` (the join script remains for ai-01) | `ansible/`, `qnsc-k3s-agent-join.sh` |

Why the template is a script, not `proxmox_download_file` + a `template = true` VM (the usual bpg pattern):
`disk.import_from` is a create-time argument the provider cannot read back, so importing the existing template
would plan a REPLACEMENT of the VM every clone depends on, and "No changes" cannot be proven without the host;
and a template is a build artefact, not desired state. The stack consumes it by id (`clone { vm_id = 9000 }`).
`pve-template-9000.sh --check` reports it, `--apply` builds it once and never deletes anything.

Order for a whole new site: `docs/runbooks/site-from-zero.md`.

## ai-01 — the GPU agent node (§9.1)

Same stack, second VM: `ai-01` (101), cloned from template 9000, 8 vCPU,
12 GiB (Phase 3; was 20) with ballooning off, 40 GiB system disk + 300 GiB model-cache disk, the
RTX 5060 Ti via the `gpu-rtx5060ti` mapping, and only the `ai` namespace by
taint. k3s-01 keeps 28 vCPU; the split leaves the hypervisor headroom.

**Order (a host reboot is in the middle of it):**

1. `scripts/owner/pve-gpu-passthrough.sh --check` then `--apply` on pve01.
2. `qm shutdown 100 --timeout 180`, `reboot`, `--check` again (all PASS),
   `qm start 100`.
3. `tofu apply` in this stack. Expected plan:
   - `1 to add` — ai-01 and its cloud-init snippet;
   - `1 to change` — VM 100 memory → its current default, **in place, needs a restart**
     (the stack keeps `reboot_after_update = false`, so nothing power-cycles
     behind your back);
   - `0 to replace` — VM 100 must not show a replacement.
4. `qm shutdown 100 && qm start 100` in the window (applies the memory change).
   ai-01 is already running; it only joins in step 5.
5. On ai-01: `bash scripts/owner/qnsc-k3s-agent-join.sh <k3s-01 address>` —
   driver r580-open + container toolkit, agent config with
   `qnsc.vn/pool=ai` + `qnsc.vn/pool=ai:NoSchedule`, and the join. The token is
   read from k3s-01 over SSH into a 0600 file in tmpfs and removed on exit.

**Driver:** NVIDIA branch **580** (`nvidia-driver-580-open`). Blackwell
(sm_120, the RTX 5060 Ti's compute capability) is supported from driver
570.86.16 onward; 580 is the current production branch. Cite: NVIDIA Unix
driver release notes for 570.86.16 ("Added support for … Blackwell") and the
CUDA 12.8 release notes for sm_120.

**After the join:**

```sh
kubectl get node ai-01 -o wide            # Ready, roles <none>, qnsc.vn/pool=ai
kubectl describe node ai-01 | grep -A2 Taints   # qnsc.vn/pool=ai:NoSchedule
ssh <ai-01> nvidia-smi                    # the RTX 5060 Ti, driver 580.x
kubectl run gpu-smoke --rm -it --restart=Never   --image=nvcr.io/nvidia/cuda:12.8.0-base-ubuntu24.04   --overrides='{"spec":{"runtimeClassName":"nvidia","tolerations":[{"key":"qnsc.vn/pool","operator":"Equal","value":"ai","effect":"NoSchedule"}]}}'   -- nvidia-smi
```

The `RuntimeClass nvidia` and the device plugin are gitops objects (namespace
`ai`); k3s only has to report the runtime, which step 2 of the join script does.

## Phase 3 — resize and vlsi-01 (2026-11-02)

Owner-local, in one maintenance window: **docs/runbooks/phase3-window.md** (snapshots, backup,
apply, verification, rollback).

| VM | change | how it shows in the plan |
|---|---|---|
| `k3s-01` (100) | memory 36 → 24 GiB (28 vCPU unchanged) | `~ memory { dedicated = 36864 -> 24576 }`, in-place |
| `ai-01` (101) | memory 20 → 12 GiB (8 vCPU unchanged) | `~ memory { dedicated = 20480 -> 12288 }`, in-place |
| `vlsi-01` (102) | **new**: clone of template 9000, 12 vCPU, 20 GiB, scsi0 40 GiB + scsi1 300 GiB on local-zfs, `cpu.units = 25`, startup order 3, no GPU, cloud-init user `qnsc` + the operator keys | `+ create` |

Expected plan: `1 to add, 2 to change, 0 to destroy`, and **no** replacement on VM 100 or 101.
Needs one new line in `site.tfvars` (git-ignored): `vlsi01_ipv4_address = "<next free address after ai-01>/24"`;
`site.tfvars.example` shows the shape.

**Does the provider reboot by itself?** bpg's `reboot_after_update` defaults to **true**: with it the provider
may reboot or power off a VM during an update when a change needs it. This stack sets it to **false** on all
three VMs, so nothing is power-cycled as a side effect: an update that cannot be applied online fails, and one
that is applied but needs a later restart (these memory changes: no memory hotplug, so the new size takes effect
at the next stop/start) emits a warning. Recommendation: **shut the VMs down first, then apply, then start**
(the runbook does this), so the memory change is written to a stopped VM and there is no pending state. Do not
flip `reboot_after_update` to true for this window: it would restart whichever VM the provider decides, at the
moment it decides.

`cpu.units`: vlsi-01 has weight 25, k3s-01 and ai-01 keep the Proxmox default (100 on cgroup v2, 1024 on v1),
so production wins when the host runs out of CPU. It only matters under contention.
