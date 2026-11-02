# live/onprem-vm

The Proxmox VM `k3s-01` (VM 100) as code. Built by hand on 2026-10-21; this
stack **imports** the existing VM and describes it as it is. Its target is a
plan that reports **no changes** for VM 100 — anything else is this file
disagreeing with the live machine.

Owner-applied only (`NOT_PLANNABLE` in `.github/workflows/infra-plan.yml`): CI
holds no Proxmox token, and the API endpoint is the admin door.

## Owns

- `proxmox_virtual_environment_vm.k3s_01` — 28 vCPU, 56 GiB (balloon off),
  q35 + OVMF, virtio-scsi-single, scsi0 120 G, scsi1 1200 G, net0 on the
  server VLAN, serial0 socket, VGA std. `prevent_destroy` is set: the VM holds
  every PVC. `reboot_after_update = false` — this stack never power-cycles the
  node as a side effect.
- `files/k3s/config.yaml` + `files/k3s/version` — the k3s server config as it
  should stand on the node, and the version pin. Applied **by hand** on the
  node; nothing here writes into a running VM.

- Proxmox API objects of the host, imported (`proxmox_iam.tf`, `proxmox_host.tf`): the user
  `terraform@pve`, the API token `tofu`, the role `TofuStartupOrder` (Sys.Modify), the ACL entries, the PCI
  mapping `gpu-rtx5060ti`, the storages `local` and `local-zfs`, and the vzdump jobs. Provider
  `bpg/proxmox ~> 0.120`. See "Proxmox API objects" and "Where IaC stops" below.

## Not managed, on purpose

- `clone {}` — every field is ForceNew, and an import never sets it. Creating a
  new site from template 9000 is its own piece of work.
- `initialization.user_data_file_id` — ForceNew, so a snippet would **replace** the
  VM. The rest of k3s-01's cloud-init (ide2, IP, DNS, user, keys) IS described, as it
  stands on the live VM.
- Tags, description — the live VM has neither, and setting one is a diff.
- Anything inside the guest (disks, filesystems, k3s install). Those are the
  node's own state; `files/k3s/*` is the source of truth for the config.

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
`files/k3s/config.yaml` is the live node's `/etc/rancher/k3s/config.yaml`, byte for byte
(verified 2026-11-02). The OIDC issuer args for ESO workload identity (infra#252) are
added in that PR, not here. Diff before any change:
```sh
scp files/k3s/config.yaml qnsc@<node>:/tmp/config.yaml
ssh qnsc@<node> 'sudo diff -u /etc/rancher/k3s/config.yaml /tmp/config.yaml'
```

`files/k3s/version` pins `vX.Y.Z+k3s1`: an upgrade is
`curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<version> sh -` on the node
after editing the file.

## Proxmox API objects (import, then No changes)

Everything here already exists on pve01, made by hand. `imports.tf` carries the `import {}` blocks; they run
on the first apply, nothing is created, and the target is a plan that reports **No changes** for them. A diff
means a `.tf` value disagrees with the host: change the file (or your `site.tfvars`), never the host.

**Site values stay local.** The ACL entries, the PCI mapping details and the vzdump jobs are variables
(`pve_acls`, `gpu_pci_mapping`, `vzdump_jobs`, default empty/null); put the real ones in the git-ignored
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

# 3. storages and backup jobs
pvesh get /storage --output-format json | jq '.[] | {storage, type, path, pool, content, nodes}'
pvesh get /storage/local --output-format json
pvesh get /storage/local-zfs --output-format json
pvesh get /cluster/backup --output-format json      # one vzdump_jobs entry per row, keyed by its id
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
| `proxmox_backup_job.managed["<id>"]` | the job id |

Then, as for VM 100: `tofu plan` must say **No changes** for all of them before any apply. Reconcile field
by field if not (`comment`, `email`, `enabled` of the user; the storage `content` and `thin_provision`;
the job fields): the host is the authority. Four things to know:

- **The token secret is not in IaC.** `proxmox_user_token.value` is only returned on creation; an import leaves it
  null, so nothing is rotated and no secret enters state. This stack authenticates with that token, so every one of
  these resources has `prevent_destroy`, and the token must never be recreated from here.
- **The user has no `password`**, for the same reason (an import cannot read it back; setting one is a write).
- **A PBS storage is not managed.** Its password cannot be imported, and an apply would try to write it. It stays
  defined by hand (`pvesm status`), listed in the site-from-zero runbook.
- **`proxmox_acl` / `proxmox_hardware_mapping_pci` / `proxmox_backup_job` / the storages use the provider's
  newer `proxmox_*` resource names** (the legacy `proxmox_virtual_environment_*` twins exist for some, not for
  `proxmox_backup_job`); the user and role, and the VMs, only exist under the legacy names.

## Where IaC stops

| Layer | Owner | Where |
|---|---|---|
| Proxmox **API objects**: VMs, users, token, role, ACLs, PCI mapping, storages, vzdump jobs | OpenTofu | this stack |
| Host **OS**: kernel cmdline (`iommu=pt`), vfio / nouveau modprobe files, initramfs, ZFS ARC limit, `snippets` on `local`, UPS/NUT, PBS install | idempotent owner scripts and runbooks run as root on pve01 | `scripts/owner/pve-gpu-passthrough.sh`, the server-setup runbook |
| The VM **template** 9000 (an Ubuntu cloud image turned into a template) | idempotent owner script | `scripts/owner/pve-template-9000.sh` |
| Inside the VMs: k3s install and config, drivers | owner scripts and the files in `files/k3s/` | `qnsc-k3s-agent-join.sh`, runbook |

Why the template is a script, not `proxmox_download_file` + a `template = true` VM (the usual bpg pattern):
`disk.import_from` is a create-time argument the provider cannot read back, so importing the existing template
would plan a REPLACEMENT of the VM every clone depends on, and "No changes" cannot be proven without the host;
and a template is a build artefact, not desired state. The stack consumes it by id (`clone { vm_id = 9000 }`).
`pve-template-9000.sh --check` reports it, `--apply` builds it once and never deletes anything.

Order for a whole new site: `docs/runbooks/site-from-zero.md`.

## ai-01 — the GPU agent node (§9.1)

Same stack, second VM: `ai-01` (101), cloned from template 9000, 8 vCPU,
20 GiB with ballooning off, 40 GiB system disk + 300 GiB model-cache disk, the
RTX 5060 Ti via the `gpu-rtx5060ti` mapping, and only the `ai` namespace by
taint. k3s-01 keeps 28 vCPU; the split leaves the hypervisor headroom.

**Order (a host reboot is in the middle of it):**

1. `scripts/owner/pve-gpu-passthrough.sh --check` then `--apply` on pve01.
2. `qm shutdown 100 --timeout 180`, `reboot`, `--check` again (all PASS),
   `qm start 100`.
3. `tofu apply` in this stack. Expected plan:
   - `1 to add` — ai-01 and its cloud-init snippet;
   - `1 to change` — VM 100 memory 57344 → 36864, **in place, needs a restart**
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
