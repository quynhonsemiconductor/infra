# AppArmor stacking: containerd's profile denies same-container signals

Incident 2026-11-03. Ubuntu 26.04 nodes, k3s v1.36.5+k3s1 (bundled containerd v2.3.4-k3s1.36 and runc under
`/var/lib/rancher/k3s/data/current/bin/`). **Temporary**: everything here goes away once the containerd bundled with
the pinned k3s ships containerd PR #14487 (issue #14485).

## Symptom

PostgreSQL (CNPG) hangs: logins time out, backends wait on latches forever, the pod stays Running but never Ready
again. Any multi-process container that signals its own processes (SIGURG, SIGUSR1, SIGTERM to children) is affected.

## Cause

Ubuntu sets `kernel.apparmor_restrict_unprivileged_unconfined=1`. With it, container processes do not run under the
plain `cri-containerd.apparmor.d` profile but under the stacked label `cri-containerd.apparmor.d//&unconfined`.
containerd's default profile only allows `signal` and `ptrace` between peers labelled exactly
`cri-containerd.apparmor.d`, so a signal from one process of a container to another process of the SAME container
is denied. Fixed upstream in containerd PR #14487, not released in the containerd k3s bundles yet.

## Evidence

```sh
ps -eo label,pid,comm | grep '//&unconfined'                   # container processes carry the stacked label
journalctl -k -b | grep 'apparmor="DENIED"' | grep 'operation="signal"' | grep cri-containerd.apparmor.d
sysctl kernel.apparmor_restrict_unprivileged_unconfined         # = 1
uname -r                                                        # which kernel is running
```

## Fix (Ansible, every k3s node)

Role `apparmor_containerd` (run by `k3s-server.yml`, `k3s-agent-gpu.yml`, `k3s-agent.yml` before k3s):

- `/etc/apparmor.d/cri-containerd.apparmor.d`: containerd 2.x's default profile plus two rules,
  `signal (send,receive) peer=cri-containerd.apparmor.d//&*` and
  `ptrace (trace,read,tracedby,readby) peer=cri-containerd.apparmor.d//&*`. Validated with `apparmor_parser -QT`
  before it is written, loaded with `apparmor_parser -r` (running containers pick it up; k3s is not restarted).
  containerd does not load its own profile when one of that name is already loaded.
- Drop-in `/etc/systemd/system/<k3s|k3s-agent>.service.d/10-apparmor.conf`: `After=` and `Requires=apparmor.service`,
  so at boot apparmor.service has loaded the override before containerd starts. Consequence: restarting
  apparmor.service also restarts k3s; reload it instead.
- Verify: counts `apparmor="DENIED" operation="signal"` lines for the profile in `journalctl -k -b`. Reports by
  default; `-e apparmor_containerd_strict=true` fails the run when the count is not 0. Denials logged before the
  override was loaded in the same boot also count.

Role `kernel` (same playbooks): unattended-upgrades keeps installing security updates and never reboots
(`Automatic-Reboot "false"`); a new kernel becomes active only at a reboot in a maintenance window. The temporary pin
is a variable in the local inventory:

- `kernel_pin_version: "7.0.0-38"`: `GRUB_DEFAULT=saved`, `grub-set-default "Advanced options for Ubuntu>Ubuntu,
  with Linux 7.0.0-38-generic"`, `apt-mark hold` of the installed kernel meta packages (`linux-image-virtual`,
  `linux-headers-virtual`, `linux-virtual`, `linux-headers-generic`).
- `kernel_pin_version: ""` (default): `GRUB_DEFAULT=0`, the meta packages are unheld.

Neither role reboots. k3s-01 was pinned by hand on 2026-11-03 to 7.0.0-38; the role reproduces that state.

## Canary: moving off the kernel pin

The override is what makes the pin unnecessary; prove it on the node with the least to lose first.

1. **vlsi-01** (no production workloads): override in place (`k3s-agent.yml`), `kernel_pin_version: ""` for it,
   run the playbook, `apt-get dist-upgrade` to the current kernel, reboot. Then:
   ```sh
   uname -r                                                     # the new kernel
   journalctl -k -b | grep 'apparmor="DENIED"' | grep -c 'operation="signal"'   # 0
   ansible-playbook k3s-agent.yml --tags apparmor_containerd_verify -e apparmor_containerd_strict=true
   ```
   Run a throwaway CNPG cluster (or any multi-process pod) tolerating `qnsc.vn/pool=vlsi:NoSchedule` on it and
   confirm it becomes Ready and accepts logins; leave it a day.
2. **k3s-01**, in a maintenance window (DB snapshot first, the phase-3 window rules apply): remove
   `kernel_pin_version` from its host vars, run `k3s-server.yml --tags apparmor_containerd,kernel`, upgrade the
   kernel, reboot. Verify 0 denials (strict verify as above), every CNPG cluster `Ready`
   (`kubectl get clusters.postgresql.cnpg.io -A`), logins work.
3. ai-01 follows in any window.

Rollback on a node: set `kernel_pin_version` back, run the playbook, reboot into the pinned kernel.

## Removal

When the pinned k3s bundles a containerd with #14487 (check the k3s release notes for the containerd version, then
the containerd changelog): drop the role from the playbooks and delete, on every node,
`/etc/apparmor.d/cri-containerd.apparmor.d` and the `10-apparmor.conf` drop-in, then reboot in a window so
containerd loads its own profile.
