# Site from zero: rebuild pve01, the VMs, k3s and the gitops layer

An OUTLINE of the order, with the owner of each step. It links to the runbooks and scripts that hold
the commands; it does not repeat them. Public repo: no addresses, hostnames or keys here (site values
live in the owner's git-ignored `site.tfvars`, kept as `sa-local/onprem-vm.site.tfvars`, and in the
private product-docs runbook `platform/runbooks/server-setup.md`).

Boundary that decides every step: **IaC = Proxmox API objects and cloud objects; host OS and guest OS =
idempotent owner scripts run as root** (`live/onprem-vm/README.md`, "Where IaC stops").

| # | Step | How | Result |
|---|---|---|---|
| 0 | Accounts and state | The Azure state account and its RBAC: `scripts/owner/bootstrap-state.sh <operator-upn>` after the by-hand pre-work in `live/identity/README.md`. Cloudflare and 1Password access are the owner's. | `tofu init` works in every stack |
| 1 | Hardware, BIOS, Proxmox install, ZFS, host config, HDD mirror, UPS | private runbook `server-setup.md` sections 0-5 (owner, at the machine) | pve01 up, `local` and `local-zfs` storages |
| 2 | GPU passthrough host config | `scripts/owner/pve-gpu-passthrough.sh --check`, `--apply`, **host reboot** (stop VMs first), `--check` all PASS; it prints the `gpu_pci_mapping` snippet for step 4 | vfio bound, IOMMU set |
| 3 | VM template 9000 | `NAMESERVER=<lan dns> scripts/owner/pve-template-9000.sh --apply` (idempotent; `--check` reports) | template 9000 |
| 4 | Proxmox API identity, **by hand once** | `pveum user add terraform@pve`; `pveum role add TofuStartupOrder -privs Sys.Modify`; `pveum user token add terraform@pve tofu --privsep 0` (the secret prints ONCE: straight into the owner's secret store, `TF_VAR_proxmox_api_token`, never a file or the repo); the ACLs (`pveum acl modify`) for `/` (PVEAdmin), `/` (TofuStartupOrder) and `/mapping/pci/gpu-rtx5060ti` (PVEMappingUser). Then copy them into `site.tfvars` (`pve_acls`, `gpu_pci_mapping`) | the identity this stack runs as |
| 5 | `live/onprem-vm` | First apply on a new site: `import {}` blocks for the identity objects (they exist from step 4), the VMs are created from template 9000 (a site that already has VM 100 imports it; see the README). **Plan must be No changes for imported objects** before any apply. Phase-3 VM sizing is not part of this. | k3s-01 and ai-01 VMs |
| 6 | k3s on k3s-01 | the server install per the private runbook section 10, config from `live/onprem-vm/files/k3s/config.yaml` and `version` (it carries the ESO issuer lines) | node Ready |
| 7 | ai-01 joins | on ai-01: `scripts/owner/qnsc-k3s-agent-join.sh <k3s-01 address>` | GPU node Ready, pool taint set |
| 8 | Identity and OIDC | `live/onprem-oidc` (publish the issuer + JWKS, needs the running cluster) -> `live/identity` (apps, federated credentials; plan counts in its README) -> the k3s issuer restart (README "ESO workload identity", steps 1-6) | ESO can reach Key Vault with no certificate |
| 9 | Doors and storage | `live/onprem` (tunnels, R2 `qnsc-backups` with its lock/lifecycle), `live/edge`, `live/storage-*` (CI plans these; the owner applies per each README) | tunnel, DNS, buckets |
| 10 | Key Vault inputs | gitops `platform/bootstrap/secrets.sh` per product/env (names in `values/<product>/<env>.secrets.yaml`; the owner pastes vendor values) | secrets exist |
| 11 | gitops bootstrap | gitops `platform/bootstrap/cluster.sh --env <dev|prod>` (ESO credentials, CNPG CA, ArgoCD, root); waves in `platform/argocd/bootstrap.md`; per extra cluster: `--pg-cluster pg-opshub` for its CA mirror | platform Applications Healthy, pg-rova up |
| 12 | Data | restore pg-rova from the R2 base backup + WAL (barman recovery, `serverName` bump) or from the latest locked dump; `kubectl -n restore-test create job --from=cronjob/pg-rova-restore-test ...` must PASS | data back |
| 13 | Verify | `tofu plan` No changes in every owner stack; ArgoCD all Healthy; `kubectl cnpg status pg-rova`; the product smoke tests; a fresh backup and dump (`DUMP-OK`) | site is production again |

Known gaps (do not discover them at 2 a.m.): the pg-rova recovery manifest is only a comment in the gitops
repo today (gitops audit G-10, a `runbooks/pg-rova-restore.md` is still to be written); the UPS/NUT
config is by hand (no IaC, secrets involved); step 4 is the one manual bootstrap of the identity the
stack itself uses. The PBS storage `pbs-qnsc` and the nightly backup job are IaC (`live/onprem-vm/backup.tf`);
the PBS server itself is the Ansible role `pbs`.
