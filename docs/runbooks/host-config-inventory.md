# Host and VM configuration: what is manual today, and where each step goes

Decision (owner, 2026-11-02): **one tool per layer**, so that a rebuilt site is a sequence of commands
and not a memory. Public repo: no addresses, hostnames of admin doors or keys here; site values live in
the owner's git-ignored files.

| Layer | Tool | Owns |
|---|---|---|
| API objects | **OpenTofu** (`live/*`) | Proxmox VMs, PVE storages, backup jobs, users/tokens/ACLs, PCI mapping; Cloudflare, Entra, GitHub, Grafana, Azure |
| OS and config of hosts and VMs | **Ansible** (`ansible/`) | packages, files, services, kernel/vfio, ZFS, PBS internals, k3s install and config, drivers |
| First boot | **cloud-init** (a snippet from OpenTofu) | hostname, one operator key, qemu-guest-agent, time zone: nothing else |
| In-cluster | **gitops** | everything Kubernetes |
| Laptops | **Fleet** (later) | the owners' Macs: WARP, known_hosts, brew |
| Secret VALUES | **manual** (1Password / Key Vault, through stdin) | never in Git, never in Ansible vars files, never in state, except where a provider has no other input: the Entra IdP client secret (`live/edge`) and the PBS storage token (`live/onprem-vm/backup.tf`, DatastoreBackup on one datastore only); the state backend is private (Entra auth) and encrypted at rest |

Priority: **P1** wave 1 (in `ansible/` now), **P2** wave 2 (next), **P3** later, **keep** = stays a manual/owner action on purpose.

## A. Scripts in this repository

| Item | Source | Goes to | Prio | Note |
|---|---|---|---|---|
| vfio / nouveau blacklist, `iommu=pt`, vfio modules, initramfs, ZFS ARC limit | `scripts/owner/pve-gpu-passthrough.sh` (apply part) | Ansible `pve_gpu` | P1 | the script's file contents are reproduced byte for byte, so a first `--check` shows no change |
| PCI mapping `gpu-rtx5060ti` | same script (`--create-mapping`, snippet printer) | OpenTofu (`proxmox_host.tf`, infra#294) | done in #294 | the script keeps a check/snippet mode until Ansible `pve_gpu` has a verified run |
| `--check` state report of the script | same script | Ansible `--check --diff` + the role's verify tasks | P1 | the script can be deleted after the first clean Ansible run |
| VM template 9000 build | `scripts/owner/pve-template-9000.sh` | Ansible role `pve_template` (qm commands, idempotent) | P2 | stays a script until then; an image rebuild is a deliberate act, not drift |
| ai-01: NVIDIA driver + toolkit + k3s agent join | `scripts/owner/qnsc-k3s-agent-join.sh` | Ansible `k3s_agent_gpu` | P1 | the join token comes from 1Password through the environment of the run, never a vars file |
| k3s server config and version pin | (was `live/onprem-vm/files/k3s/`) | Ansible `k3s_server` + `group_vars/k3s.yml` | done | ONE source; the files/ copy was deleted (it lacked the ESO issuer lines). OIDC issuer is a site value, default off |
| kubelet reservations, eviction and graceful shutdown (all nodes) | hand-written `90-qnsc.conf` on k3s-01 only | Ansible `kubelet` (drop-in `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/90-qnsc.conf`) | P1 | server 1 CPU/2 Gi, agents 500m/1 Gi; shutdown 120 s/60 s; image GC 336 h; restart gated |
| Azure state account preflight | `scripts/owner/bootstrap-state.sh` | keep | keep | a one-time Azure bootstrap run from a laptop with `az`; chicken-and-egg with OpenTofu |
| Exchange mailbox scoping (PowerShell) | `scripts/owner/mail-prod-tenant/` | keep (no provider for Exchange RBAC) | keep | documented in live/identity README |
| Read-only kubeconfig for the operator | `scripts/owner/kubeconfig-ro.sh` | keep | keep | secret handling into 1Password |
| Entra IdP secret rotation | `scripts/rotate-idp-secret.sh` | keep | keep | rotation is a deliberate act |

## B. Hand steps recorded in the runbooks and notes

| Step | Where it is written | Goes to | Prio | Note |
|---|---|---|---|---|
| Disable the enterprise repos, add no-subscription | server-setup.md 3.1 | Ansible `pve_base` | P1 | detects an existing no-subscription source and does not add a second one |
| Unattended security updates | (none: done by hand) | Ansible `pve_base` | P1 | Debian security origin only, never an automatic reboot |
| chrony sources | server-setup.md 3.4 | Ansible `pve_base` | P1 | |
| SSH: key only, no root password | server-setup.md 3.2, MANUAL-STEPS | Ansible `pve_base` | P1 | refuses to run if the connecting user has no authorized key |
| Root TOTP, password manager seed | server-setup.md 3.2 | keep | keep | a secret seed |
| `jq` and small tools on the host | (missing today) | Ansible `pve_base` | P1 | |
| ZFS properties (atime, compression), `local-zfs` sparse/blocksize | server-setup.md 3.3 | atime/compression: Ansible `pve_base`; storage options: OpenTofu `proxmox_storage_zfspool` | P1 | |
| ZFS ARC limit | server-setup.md 3.3 | Ansible `pve_gpu` (with the other module options) | P1 | |
| HDD mirror pool `backup` | server-setup.md 4 | keep | keep | destroys disks: created once by hand, Ansible only creates the dataset on it |
| UPS (NUT) | server-setup.md 5 | Ansible `pve_nut` | P2 | |
| PBS install, datastore, prune/GC/verify, user and token | server-setup.md 11 | Ansible `pbs` | P1 | the PBS user token secret goes to 1Password through stdin, never to a log |
| PVE side of PBS (storage, nightly job) | server-setup.md 11.3 | OpenTofu `proxmox_storage_pbs` + `proxmox_backup_job` (`live/onprem-vm/backup.tf`) | done | no client-side encryption while the datastore is on the same host; add it with the off-site copy (key created once, kept in 1Password) |
| Backup restore test | server-setup.md 11.4 | keep (quarterly runbook) | keep | a human checks the VM boots |
| k3s-01: k3s install and config | server-setup.md 10 | Ansible `k3s_server` | P1 | restart is gated by a variable (default: report, do not restart) |
| Ubuntu base of the VMs (users, sshd, unattended upgrades) | server-setup.md 10, cloud-init | cloud-init stays minimal; the rest Ansible `vm_base` | P2 | |
| Proxmox VMs 100/101, PVE users/ACLs, PCI mapping, storages | server-setup.md 9, 11 | OpenTofu (`live/onprem-vm`, infra#294) | done | |
| Template 9000 | server-setup.md 7 | see A | P2 | |
| Remote access, tunnels, Access | server-setup.md 12 | OpenTofu `live/onprem`, `live/edge` | done | |
| Cluster bootstrap (ESO credentials, CA, ArgoCD) | server-setup.md 14 | gitops `cluster.sh` | done | |
| Monthly maintenance (updates, scrub, SMART) | server-setup.md 15 | Ansible `--check --diff` as a drift report; apt upgrades stay a deliberate window | P2 | |
| Key Vault secret values, token values | MANUAL-STEPS.md | keep | keep | by design |
| Laptop `known_hosts`, WARP client | owner steps of 2026-11-02 | Fleet | later | |
| GitHub variables/rulesets | MANUAL-STEPS.md | OpenTofu `live/github` (merged) | done | |
| Router / VLAN / ISP line | MANUAL-STEPS.md | keep | keep | a network device with no API in scope |

## C. Cloud-init snippets

| Snippet | Content today | Decision |
|---|---|---|
| ai-01 user data (`live/onprem-vm/ai01.tf`) | hostname, hosts file, time zone, operator keys, qemu-guest-agent, chrony | **stays**: this is the minimum for Ansible to reach the VM. Everything else about ai-01 (driver, k3s) is Ansible |
| k3s-01 initialization (`live/onprem-vm/vm.tf`) | user, keys, DNS, address (described, not replaced) | stays as is |
| vlsi-01 initialization (`live/onprem-vm/vlsi01.tf`) | user, keys, DNS, address; **no** user data | stays as is. The stock Ubuntu cloud image behind template 9000 has **no qemu-guest-agent** (vlsi-01 booted without one, 2026-11-03), so the guest agent is not a first-boot item that can be assumed |

**qemu-guest-agent** is owned by the Ansible role `vm_guest`, the first role of every VM playbook (`k3s-server.yml`,
`k3s-agent-gpu.yml`, `k3s-agent.yml`): installs the package and starts `qemu-guest-agent.service` (a static unit that
udev starts when the agent's virtio port appears; nothing to enable); it refuses a VM whose config has no agent port.
Template 9000 should carry it too, so `qm guest cmd` works before Ansible has run: `scripts/owner/pve-template-9000.sh`
imports the stock cloud image unchanged today; add it at the next template rebuild (`virt-customize -a <image>
--install qemu-guest-agent` before the import, which needs `libguestfs-tools` on the host). Until then a fresh clone
gets the agent from its first `vm_guest` run.

## D. Order for a new or rebuilt site

See `docs/runbooks/site-from-zero.md`; the Ansible half is `ansible/README.md`.

## E. What Ansible must never do

- never hold or print a secret value: tokens come from the environment of the run (`op run`) or are
  generated on the host and handed to 1Password through stdin; every task that touches one has `no_log`;
- never reboot a host or restart k3s by itself (variables say "report" by default);
- never create or destroy a disk or a pool;
- never run from CI against real hosts: CI only lints and syntax-checks.
