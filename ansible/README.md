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

The four non-secret site values live in the LOCAL inventory (nothing in Git), next to the host. The shared
`proxmox_entra_admin_emails` is the platform admins' Entra `email` claim values (owner-held; keep them equal
to the app's direct assignments and `grp-qnsc-platform-admins`). Use the EXACT strings Entra returns — PVE and
PBS user ids are case-sensitive. `pbs_entra_admin_emails` is still accepted as a compat alias. The group
object id is `az ad group show --group grp-qnsc-platform-admins --query id -o tsv`:

```yaml
pve:
  hosts:
    pve01:
      # ...
      proxmox_oidc_issuer_url: "https://login.microsoftonline.com/<tenant>/v2.0"   # step 3 output
      proxmox_oidc_client_id: "<application (client) id>"                          # step 3 output
      proxmox_oidc_admin_group_oid: "<object id of grp-qnsc-platform-admins>"
      # ONE shared admin list for both realms. PVE pre-creates <email>@entra and makes each one a member
      # of <oid>-entra; PBS pre-creates the same users and grants Admin on /. Keep it equal to the app's
      # direct assignments and the platform-admins group.
      proxmox_entra_admin_emails: ["<admin1>@<domain>", "<admin2>@<domain>"]
```

**Why my group changed on login (and why the role does not use the claim).** PVE asks the provider's
`userinfo` endpoint for claim values: `src/PVE/API2/OpenId.pm` passes `query-userinfo` with a default of 1,
then reads `groups-claim` from the returned info (PVE docs, "Query userinfo endpoint",
<https://pve.proxmox.com/pve-docs/chapter-pveum.html#pveum_openid>). Microsoft's userinfo response returns
only the OIDC standard name/subject/email claims and **cannot be customized** — the app's SecurityGroup
`groups` claim lives in the ID token, not in userinfo (Microsoft Learn, "UserInfo endpoint",
<https://learn.microsoft.com/en-us/entra/identity-platform/userinfo>). So `pve_base_entra` does not rely on
the claim: it pre-creates `<email>@<realm>` for every list entry, makes each one a member of
`<group-oid>-entra`, and removes members no longer listed (offboarding). The realm keeps `autocreate=0`
(only listed admins may exist) and `groups-overwrite=0` (a login never wipes the membership). On an
existing realm the role also deletes the legacy `groups-claim` / `groups-autocreate` settings
(`pveum realm modify <realm> --delete groups-claim,groups-autocreate`) so the configuration converges and
drift includes them. PBS already works this way: pre-created user + per-user ACL. A `--check` run reports
each pending create/addition/removal; a second run is `changed=0`.

A **PVE-only** inventory may omit the shared list entirely: the realm, group and ACL are still managed,
and only the user pre-creation/membership/offboarding tasks are skipped. When the list is present it must
hold exact Entra email strings with no duplicates, and the same `proxmox_entra_admin_emails` (canonical)
wins over the legacy `pbs_entra_admin_emails` in both roles.

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

## ZFS ARC ceiling (`pve_base_zfs`)

`pve_base` owns `/etc/modprobe.d/zfs.conf` (one `options zfs zfs_arc_max=8589934592` line) and applies
the live `/sys/module/zfs/parameters/zfs_arc_max`. It refuses a file whose `options zfs` line carries
other settings instead of overwriting them; merge by hand and re-run. The initramfs handler rebuilds,
and no reboot is needed. After a run that changed the value:

```sh
proxmox-boot-tool status                                  # boot entry/initramfs is current
cat /sys/module/zfs/parameters/zfs_arc_max                # 8589934592
```

`--check` reports the pending file line and live change; `pve-host.yml --tags pve_base_zfs` converges just this.
## SSH for people (`ssh_infra`): Cloudflare Access for Infrastructure

Owner decision 2026-11-05: no shared passwords and no long-lived personal
keys. A platform admin enables WARP (`live/edge/warp.tf` already mirrors the
office range into the tunnel: `admin_private_cidr` is removed from the default
split-tunnel excludes), runs `ssh <user>@<node address>`, and Cloudflare's
Gateway SSH proxy checks Entra + MFA and issues a **short-lived SSH
certificate**. The node trusts the account's Access SSH CA; the CA public key
is the only trust anchor.

**Free-plan check.** Cloudflare's docs list Access for Infrastructure under
Zero Trust plans **All plans** (<https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/infrastructure-apps/>).
Confirm it is enabled in the account's Zero Trust dashboard before applying;
if it is not offered, STOP and report — the fallback is Ansible-managed public
keys, not a downgrade to passwords.

### 1. Cloudflare (IaC, `live/edge/ssh_infra.tf`)

Targets and usernames come from the `TF_VAR_ssh_infra_targets` JSON (a repo
secret / owner env file; no address or person name is committed):

```json
{
  "ai-01": { "hostname": "ai-01", "ipv4": "<ai-01 address>", "usernames": ["<admin login>"] }
}
```

Apply `live/edge`: one `cloudflare_zero_trust_access_infrastructure_target`
per node and one infrastructure application (SSH/22) per target. Its policy
allows `grp-qnsc-platform-admins`, requires `amr=mfa`, and restricts the UNIX
usernames. The provider has no gateway-CA resource, so the account CA is read
or created once with the owner script:

```sh
CLOUDFLARE_ACCOUNT_ID=<account-id> CLOUDFLARE_API_TOKEN=<token> \
  scripts/owner/cloudflare-ssh-ca.sh
```

The token needs **Access: SSH Auditing — Edit**. The printed public key goes
into the LOCAL inventory as `node_ssh_ca_public_key` (a public key, not a
secret; still never committed). The script uses `POST /accounts/<id>/access/gateway_ca`
only when no CA exists; a per-app `zero_trust_access_short_lived_certificate`
CA is **not** compatible with the Gateway SSH proxy.

### 2. Nodes (Ansible role `ssh_infra`)

Local inventory (git-ignored; names and addresses stay here):

```yaml
node_ssh_ca_public_key: "ssh-ed25519 AAAA... "
node_admin_users:
  # hosts = VM names in this inventory; sudo = passwordless sudo (identity + MFA happen at Cloudflare)
  - { name: <admin login>, sudo: true, hosts: [ai-01] }
```

The role (tags `ssh_infra`) is included by `k3s-agent-gpu.yml` only — ai-01
today. **A node with no entry in `node_admin_users` is never touched**; add the
role to another playbook and a target in `TF_VAR_ssh_infra_targets` when that
node gets users. It writes `/etc/ssh/ca.pub` and a `sshd_config.d` drop-in with
`TrustedUserCAKeys` plus `AuthorizedPrincipalsFile` (one principal per account,
`%u`), validates the MERGED config with `sshd -t`, and on failure restores the
previous drop-in and fails without reloading. For each listed account it creates
the user with **no password and no authorized_keys**, adds `video,render` on the
GPU node, writes a `sudoers.d` file when `sudo: true`, and a principal file
containing exactly the login name. Reserved/operator names (`root`, `qnsc`,
`ubuntu`, system accounts) are refused, and so is any pre-existing account this
role did not create. Removed from the list → the account is locked (expiry in
the past), its sudoers and principal files are removed, and the home stays; the
name stays in the marker so a failed lock is retried next run. An empty CA key
**removes** the drop-in, `/etc/ssh/ca.pub` and the principal directory (a real
revoke, not a silent skip). The break-glass operator account is never touched.

```sh
ansible-playbook k3s-agent-gpu.yml --tags ssh_infra --check --diff   # plan
ansible-playbook k3s-agent-gpu.yml --tags ssh_infra                  # apply
```

Re-run the same command: `changed=0`.

**Dry-run a removal** (proves offboarding before it happens): delete one
`node_admin_users` entry, run `--check --diff`; expect
`would lock <login> (home kept) and remove its certificate principal`. Re-add
the entry to cancel, or run without `--check` to complete the offboarding.

### 3. Verify

1. Owner: WARP connected, `warp-cli status`; then `ssh <login>@<ai-01 address>`
   (no password prompt, no local key prompt).
2. **Certificate principal:** `ssh -v` shows the offered certificate; run
   `ssh-keygen -L -f <cert file>` on it and confirm `Principals:` equals the
   UNIX login exactly (one principal per account, enforced by
   `AuthorizedPrincipalsFile`). A different name is refused even with a valid
   Cloudflare signature.
3. Cloudflare dashboard → Access → Logs shows the SSH session for the user.
4. On the node: `getent passwd <login>`, `sudo -n true` works for a sudo
   account, and `nvidia-smi` works on ai-01 (the single 16 GiB GPU is shared
   with kb prod TEI: check it is not mid-job before testing, and never start a
   model to "test" access).

`NOPASSWD` sudo for a certificate-only account is **accepted by the owner
(2026-11-06)**: the account has no password or key, and the identity + MFA
check happens at Cloudflare before sudo is reachable.

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
