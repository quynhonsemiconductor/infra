# ansible/

The OS and configuration layer of the on-prem hosts and VMs. The boundary between the tools is in
`docs/runbooks/host-config-inventory.md`: OpenTofu owns API objects, **Ansible owns what runs inside a
host or VM**, cloud-init only does the first boot, gitops owns the cluster.

```
ansible.cfg            run from this directory; the inventory is inventory/local/hosts.yml (git-ignored)
requirements.yml       pinned collections        requirements-dev.txt   pinned ansible-core and ansible-lint
inventory/example/     the shape of the local inventory (documentation addresses)
group_vars/            values that are NOT site values (pins, hardware model ids)
ping.yml               reach every host and become root
roles/, *.yml          wave 1: pve-host.yml (pve_base, pve_gpu, pbs, pve_monitoring), k3s-server.yml,
                       k3s-agent-gpu.yml, k3s-agent.yml (vlsi); every k3s playbook first runs vm_guest,
                       apparmor_containerd and kernel
```

## Set up (once, on the operator's machine)

```sh
cd ansible
python3.13 -m venv ~/.venvs/qnsc-ansible && . ~/.venvs/qnsc-ansible/bin/activate   # 3.12 to 3.14
pip install -r requirements-dev.txt
ansible-galaxy collection install -r requirements.yml -p .collections
mkdir -p inventory/local && cp inventory/example/hosts.yml inventory/local/hosts.yml   # then edit it
ansible-playbook ping.yml
```

## Rules every role follows

- **Idempotent and `--check --diff` friendly.** The first `--check` against a host that was built by hand must show
  (almost) no change: that is the proof that the role describes reality. Read-only probes use
  `check_mode: false`; anything that changes state is skipped or reported in check mode.
- **No secret value in Git, in a vars file or in a log.** Tokens come from the environment of the run
  (`op run --env-file=<local template> -- ansible-playbook ...`) or are generated on the host and handed to
  1Password through stdin; every task that touches one has `no_log: true`.
- **No reboot and no service restart that interrupts workloads by itself.** Roles report "reboot/restart needed";
  a variable per role allows the restart (default off).
- **No disks, no pools.** Ansible never creates or destroys a pool or a partition.
- **CI never touches a host.** `.github/workflows/ansible-lint.yml` runs ansible-lint and `--syntax-check` only.

## Proxmox host metrics (`pve_monitoring`)

`pve-host.yml --tags pve_monitoring` installs node-exporter (textfile collector only), a 5-minute
ZFS/NVMe/PBS/apt script, and Grafana Alloy, which pushes the resulting `pve_*` series over OTLP to the
cluster's `alloy-otlp-host` NodePort. Besides ZFS, NVMe, PBS fill and the heartbeat, the script exports
`pve_apt_updates_pending`, `pve_apt_security_updates_pending` (`-1` = apt simulation failed, unknown) and
`pve_apt_reboot_required` (1 = `/run/reboot-required` exists, or the newest installed kernel is not the
running one). It needs one site value in the git-ignored
local inventory — the endpoint of a k3s node on that NodePort:

```yaml
pve:
  hosts:
    pve01:
      ansible_host: 192.0.2.10
      ansible_user: root
      pve_monitoring_otlp_endpoint: "http://192.0.2.20:30418"
```

The role asserts it rather than installing a collector that sends nowhere. Node-exporter binds to loopback; no new
port is opened on the host.

**The OTLP door is LAN-reachable and unauthenticated.** `alloy-otlp-host` (NodePort 30418) admits RFC1918 sources
and filters metrics by `service.name`/name; it does not authenticate them. Pinning the source to pve01 would require
the host's address in the public GitOps repo (NetworkPolicy `ipBlock` cannot read a Secret, and there is no policy
engine here), so the source restriction is deliberately left out of GitOps. Mitigations in place: RFC1918-only
NetworkPolicy, the PVE metric-name allowlist, and the host sending only `pve_.*`. If the owner wants a strict source
pin, add a node-firewall rule allowing only pve01 → 30418; that keeps the address in the site firewall, not in Git.

## Entra OpenID login (`pve_base_entra`, `pbs_entra`)

Both the Proxmox VE realm and the Proxmox Backup Server realm use the ONE "QNSC Proxmox" app from
`live/identity/proxmox.tf` (one client id, one secret, one direct-assignment list). The realms, the PVE
group and the PBS per-user ACLs are Ansible's job; the manual sequence and verification are in the
platform runbook (product-docs, server-setup §3.2.1). `root@pam` is never touched — it is the break-glass
account (LAN, password + TOTP); the role fails if it is missing or disabled.

The full ordered owner sequence is in `live/identity/README.md`, "Proxmox VE + PBS login": **1** identity
plan (both redirect URIs, same run as #402) → **2** go/no-go → **3** apply + outputs → **4** client secret
into `kv-qnsc-admin` → **5** this inventory → **6** `--check` then run. Do not start at step 5: the realms
need the applied app and the vault secret first.

The four non-secret site values live in the LOCAL inventory (nothing in Git), next to the host. The two
`pbs_entra_admin_emails` are the platform admins' Entra `email` claim values (owner-held; keep them equal
to the app's direct assignments and `grp-qnsc-platform-admins`). The group object id is
`az ad group show --group grp-qnsc-platform-admins --query id -o tsv`:

```yaml
pve:
  hosts:
    pve01:
      # ...
      proxmox_oidc_issuer_url: "https://login.microsoftonline.com/<tenant>/v2.0"   # step 3 output
      proxmox_oidc_client_id: "<application (client) id>"                          # step 3 output
      proxmox_oidc_admin_group_oid: "<object id of grp-qnsc-platform-admins>"
      # PBS has no group-claim option: its admins are pre-created and get Admin on /. Keep this list
      # equal to the app's direct assignments and the platform-admins group.
      pbs_entra_admin_emails: ["<admin1>@<domain>", "<admin2>@<domain>"]
```

The client secret comes from the environment of the run (Key Vault `kv-qnsc-admin`,
`admin-proxmox-oidc-secret`, created in identity step 4 with `scripts/rotate-signin-secret.sh`):

```zsh
export PROXMOX_OIDC_CLIENT_SECRET="$(az keyvault secret show --vault-name kv-qnsc-admin \
  --name admin-proxmox-oidc-secret --query value -o tsv --only-show-errors)"
ansible-playbook pve-host.yml --check --diff --tags pve_base_entra,pbs_entra
ansible-playbook pve-host.yml --tags pve_base_entra,pbs_entra
unset PROXMOX_OIDC_CLIENT_SECRET
```

The `--check` run must be clean before the real run, and the first login on each door must show no
`AADSTS50011` (redirect URI mismatch). An ordinary run needs no secret once both realms exist (drift
changes never rewrite the key). A rotation appends a credential, stores it in Key Vault, then runs both
roles with `-e pve_base_entra_rotate_client_key=true -e pbs_entra_rotate_client_key=true`; the old
credential is revoked after a green login on both doors. The key is momentarily in
`pveum`/`proxmox-backup-manager` argv on pve01 (single-admin host); the runbook states the caveat.

## PBS API token

The `pbs` role never handles the token secret (and cannot run `op` itself: 1Password app integration only answers
the owner's own terminal). When the token is missing, the role stops; run this from your terminal with `op` signed
in, then re-run `pve-host.yml --tags pbs` (it grants the token ACL). The secret only exists in a shell variable.

```zsh
set -o pipefail; op whoami >/dev/null && \
t=$(ssh root@<pve host> 'proxmox-backup-debug api create /access/users/backup@pbs/token/pve --output-format json') && \
printf %s "$t" | jq -e '(.value|length>0) and (.tokenid=="backup@pbs!pve")' >/dev/null && \
printf %s "$t" | jq '{title:"PBS - pve backup - API token",category:"API_CREDENTIAL",
  fields:[{id:"credential",label:"secret",type:"CONCEALED",value:.value},
          {id:"tokenid",label:"token id",type:"STRING",value:.tokenid}]}' \
| op item create --vault QNSC >/dev/null && echo STORED; unset t
```

No `STORED`: do not re-run it blindly. Check `proxmox-backup-manager user list-tokens backup@pbs` on the host; a
token without a stored secret is deleted with `proxmox-backup-manager user delete-token backup@pbs pve`.
