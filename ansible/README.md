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

`pve-host.yml --tags pve_monitoring` installs node-exporter (textfile collector only), a 5-minute ZFS/NVMe/PBS
script, and Grafana Alloy, which pushes the resulting `pve_*` series over OTLP to the cluster's
`alloy-otlp-host` NodePort. It needs one site value in the git-ignored local inventory — the endpoint of a k3s
node on that NodePort:

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
