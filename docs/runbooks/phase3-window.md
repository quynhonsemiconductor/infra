# Phase 3 window: resize k3s-01 and ai-01, create vlsi-01

Owner-local (Proxmox admin door, `live/onprem-vm`). Nothing here runs in CI.
Expected **downtime of rova prod: about 3-5 minutes** (k3s-01 stopped, applied, started, workloads back).
Everything else (ArgoCD, Alloy, pg-dev, the dev products) is down for the same time.

## What changes

| VM | now | after |
|---|---|---|
| `k3s-01` (100) | 36 GiB, 28 vCPU | **24 GiB**, 28 vCPU |
| `ai-01` (101) | 20 GiB, 8 vCPU, GPU | **12 GiB**, 8 vCPU, GPU |
| `vlsi-01` (102) | - | **new**: 20 GiB, 12 vCPU, 40 GiB + 300 GiB disks, `cpu.units` 25, no GPU, startup order 3 |

Sizes: 24 + 12 + 20 = 56 GiB of the host's ~60 GB usable. That is tight; check `free -g` on the host before
the window and stop here if less than ~60 GiB is free once the three VMs are off.

## Before the window (day before, nothing changes)

1. `site.tfvars` has `vlsi01_ipv4_address` (next free address after ai-01, CIDR) and the new memory values.
2. On the PR branch: `tofu plan -out=tfplan` in `live/onprem-vm` shows exactly
   `1 to add, 2 to change, 0 to destroy`: memory on 100 and 101 in place, vlsi-01 created, **nothing** replaced.
   Anything else: stop and fix the config, never apply.
3. Host: `zpool list` (room for 300 + 40 GiB, plus the snapshots below) and `free -g`.
4. Host cgroup: `stat -fc %T /sys/fs/cgroup` (`cgroup2fs` = default weight 100) and `qm config 100 | grep -i cpuunits`
   (no line = default). `cpu.units = 25` is lower than the default either way.
5. Silence alerting for the window (Grafana > Alerting > Silences, 30 min): `k3s-pg-rova-not-ready`,
   `k3s-node-down`-style node rules, `rova-prod-readyz-down`, `k3s-valkey-prod-down`, `k3s-job-failed`.
   Tell the team.

## The window

### 1. Snapshots of VM 100 and 101 (rollback point)

On the Proxmox host, **before** anything is stopped (crash-consistent is enough; step 2 is the data safety net):

```sh
qm snapshot 100 pre-phase3 --description "before Phase 3 resize"
qm snapshot 101 pre-phase3 --description "before Phase 3 resize"
qm listsnapshot 100; qm listsnapshot 101      # both show pre-phase3
```

Both VMs use local-zfs, so these are ZFS snapshots of every disk (EFI included). No RAM state (`--vmstate` is
off, and a passthrough VM cannot save it anyway). Snapshots hold space as the data changes: **delete them after
the soak** (`qm delsnapshot 100 pre-phase3`).

### 2. Backup of pg-rova and the last dump

```sh
kubectl apply -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: pg-rova-pre-phase3, namespace: data-prod }
spec:
  cluster: { name: pg-rova }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
YAML
kubectl -n data-prod get backup pg-rova-pre-phase3 -w         # wait for phase: completed
kubectl -n data-prod get cronjob pg-rova-dump                 # LAST SCHEDULE / last success within 24 h
kubectl -n data-prod get jobs -l app.kubernetes.io/name=pg-rova-dump --sort-by=.status.startTime | tail -3
```

Do not continue until the backup is `completed` and the last dump Job succeeded (the dump is the locked, immutable
restore source).

### 3. Shut down, apply, start

Shut the VMs down **first**: the memory change is then written to a stopped VM, so no pending state and no
provider-driven reboot. (The stack keeps `reboot_after_update = false` on purpose; see live/onprem-vm/README.md.)

```sh
# on the host
qm shutdown 101 --timeout 120
qm shutdown 100 --timeout 180
qm status 100; qm status 101                   # both: stopped

# on your laptop, in live/onprem-vm (same env as the first apply)
tofu plan -out=tfplan                          # re-read: still 1 add, 2 change, 0 destroy
tofu apply tfplan
```

Then on the host: `qm config 100 | grep memory` (24576), `qm config 101 | grep memory` (12288),
`qm config 102` (12 cores, 20480, cpuunits 25, startup order=3). `started = true` is in the config, so the provider
normally powers the VMs on at the end of the apply; **check `qm status` and start what is stopped, in this order**:

```sh
qm start 100        # k3s-01 first: it is the server
# wait for the node (step 4), then:
qm start 101        # ai-01
qm start 102        # vlsi-01 (created by the apply; may already be running)
```

If the apply fails midway, do not retry blindly: read the error, `qm status` each VM, and go to Rollback.

### 4. Verify (k3s-01 back first)

```sh
kubectl get nodes                                          # k3s-01 Ready (then ai-01 Ready)
kubectl -n argocd get app                                  # all Healthy/Synced (root may show OutOfSync briefly)
kubectl -n data-prod get cluster pg-rova                   # Cluster in healthy state, 1/1
kubectl cnpg status pg-rova -n data-prod                   # if the plugin is installed
kubectl -n data-prod get pods                              # pg-rova-1, valkey-rova Running
curl -fsS https://rova.qnsc.vn/readyz                      # {"status":"ok",...}
kubectl get pods -A | grep -v -E 'Running|Completed'       # nothing unexpected
```

Then confirm in Grafana that the metrics are flowing again (Alloy) and **remove the silences**.
Rova prod downtime is the time between `qm shutdown 100` and the `/readyz` answer above.

### 5. vlsi-01 joins the cluster

vlsi-01 is a plain Ubuntu clone with the `qnsc` user and the operator keys. Configure it with the Ansible role
**`k3s-agent`** (lane D builds the roles; reference only here): join it to k3s-01 as an agent with the node label
`qnsc.vn/pool=vlsi` and the taint `qnsc.vn/pool=vlsi:NoSchedule`, no GPU driver. Then:

```sh
kubectl get node vlsi-01 --show-labels | grep qnsc.vn/pool=vlsi
kubectl describe node vlsi-01 | grep -A2 Taints            # qnsc.vn/pool=vlsi:NoSchedule
```

Nothing is scheduled there until a workload tolerates the taint.

## Rollback

Decide quickly: a rollback is clean only **before the restarted database has accepted writes**.

- **VM 100 or 101 will not boot, or the node never gets Ready** (nothing wrote yet):
  ```sh
  qm stop 100; qm rollback 100 pre-phase3; qm start 100     # same for 101
  ```
  The VM has its old memory again. `tofu` state still says the new values: either revert the PR (old defaults)
  or run `tofu apply` again in a later window; do not apply while the rollback is being investigated.
- **vlsi-01 is wrong**: it is new, so it needs no rollback: leave it stopped (`qm stop 102`) and fix forward, or
  remove it deliberately (drop `prevent_destroy` in its own PR, then `tofu destroy -target`).
- **After pg-rova has been up for a while** (it archived WAL, took writes): a snapshot rollback rewinds the
  database behind WAL already in R2 and breaks archiving. Do **not** roll back; restore from the
  `pg-rova-pre-phase3` backup and the WAL archive instead (gitops runbook for pg-rova restore), or fix forward.

Snapshots are the rollback, the CNPG backup and the locked dump are the data safety net, and the 14-day lock on
`dumps/` is the immutable one.

## After

- Keep the `pre-phase3` snapshots until the soak after Phase 3 ends, then `qm delsnapshot 100 pre-phase3` and `101`.
- Update the sa-notes/BOARD (sizes, vlsi-01) and the node-sizing figures in gitops (`platform/ai` memory notes) if
  they quote 36 / 20 GiB.
