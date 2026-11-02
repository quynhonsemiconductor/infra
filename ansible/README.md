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
roles/, *.yml          wave 1: pve-host.yml (pve_base, pve_gpu, pbs), k3s-server.yml, k3s-agent-gpu.yml,
                       k3s-agent.yml (vlsi); every k3s playbook first runs vm_guest, apparmor_containerd and kernel
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
