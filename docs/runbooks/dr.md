# Disaster recovery: three tiers, and what comes back from where

One page for the three failures that are actually possible on this site. It does not repeat the
commands that live in the step runbooks; it says which tier you are in, what to restore, in what
order, and how long it should take.

Public repo: no addresses, hostnames, tokens or keys here. Site values are in the owner's
git-ignored `site.tfvars` / local Ansible inventory and in 1Password.

## The tiers

| Tier | What is lost | Restore from | Target RTO | RPO |
|---|---|---|---|---|
| **A** | A pod, app or namespace deleted, or a database corrupt/deleted. Host, VMs and PBS are fine. | GitOps resync (objects); R2 `qnsc-backups` (database) | minutes (objects); ≤ 1 h (database) | none for objects; ≤ 15 min (WAL), last dump 24 h |
| **B** | The NVMe (or the whole Proxmox install on it). The HDD mirror with the PBS datastore survives. | PBS on the HDD mirror, then R2 for database catch-up | 3–4 h | PBS nightly (≤ 24 h) + WAL (≤ 15 min) |
| **C** | The site: host, both disk sets, or the building. | Git, 1Password, Key Vault, R2 | 1 business day | R2 only |

The expected disaster is **B**, not C: one consumer NVMe with no power-loss protection carries every
VM. That is why B is written down and rehearsed, and C is the outline in
[`site-from-zero.md`](site-from-zero.md).

Host facts (2026-11-04): the NVMe is healthy (0% wear, 0 media errors, 62 power-on hours) but the
SMART history records **4 unsafe shutdowns**; the `backup` pool is a 2x4 TB HDD mirror, ONLINE.
The UPS is the mitigation for the shutdowns until a second NVMe exists (owner decision: not now).
If the host lost power again, tier B is the plan.

## What lives where

| Source | Holds | Survives |
|---|---|---|
| Git (`infra`, `gitops`) | desired state: VMs, DNS/tunnels, k3s/Ansible config, Kubernetes objects | any tier |
| 1Password | site values: Proxmox API token, PBS token, ArgoCD admin password, tunnel token, R2 credentials | any tier |
| Azure Key Vault | application secret VALUES, ESO federated identity (no stored credential) | any tier |
| R2 `qnsc-backups` | `pg-rova/` WAL + base, `pg-opshub/` WAL + base, `dumps/`, `files/`, `dev/` | any tier |
| PBS (`backup` pool, HDD mirror) | whole-VM snapshots of 100, 101, 102 | A, B |
| Azure state account | OpenTofu state for every stack | any tier |
| The VMs' own disks | k3s sqlite datastore, local-path volumes, container images | A |

Not recoverable from Git, by design: the k3s server token and service-account signing key (they
regenerate on a rebuild; step 8 of site-from-zero republishes the JWKS), and the site's private
values (1Password is their home).

Decision (audit L5): **sqlite + one control plane stays**. On one host, an HA control plane or
embedded etcd adds I/O and moving parts for no availability gain. Cluster state is rebuilt from
GitOps; the server token and signing key regenerate; the data that matters is in PBS and R2.

## Tier A — an app object or a database is lost, the host is fine

### A1 — a pod, Deployment, Service or namespace was deleted

Git is the desired state; ArgoCD is the restore path. In the ArgoCD UI, **Refresh** then **Sync** the
Application that owns the object (or wait for self-heal, which is on for the product Applications).
If a whole namespace was deleted, sync the namespace Application first, then its workloads. Nothing
comes from PBS or R2; no data is lost. If the object carried a PVC that was deleted with it, the data
is gone and this becomes A2 (or a restore from the last dump).

### A2 — a database is corrupt or deleted

1. **Stop writes to the affected product.** Scale its API/worker to zero (or put the ingress route
   into maintenance) so the recovery is not racing new writes. Do not delete the old cluster or its
   PVCs yet: it is the last local copy and may still be readable.
2. **Recover pg-rova/pg-opshub from R2.** CNPG object-store recovery, with the archive generation
   bumped (`serverName: pg-rova-g2`, `pg-opshub-g2`) so the new cluster never writes into the old
   archive. Today the recovery manifest is a comment in `gitops platform/cnpg/pg-rova.yaml`; the
   full procedure is the outstanding gitops runbook G-10. Until it exists, use the barman recovery
   notes in that file and the CNPG "recovery from object store" flow — the archive prefix and the
   R2 credentials are already in the cluster (`pg-rova-backup.yaml`).
3. **If R2/barman is unusable**, restore the newest dump instead: download
   `dumps/daily/pg-rova-YYYY-MM-DD.dump` (or weekly/monthly), then
   `pg_restore -d <empty database> --no-owner <file>`. The dump jobs' logs say `DUMP-OK` with the
   byte count and SHA-256; a dump that did not log that line is not a restore candidate.
4. **Verify before switching traffic back:**
   `kubectl cnpg status <cluster>`, the product's smoke test, and
   `kubectl -n restore-test create job --from=cronjob/<product>-restore-test <name>` must PASS.
5. **Then** delete the failed cluster and its PVCs (the VM-rollback rule, ONPREM-PLAN §10.5: the
   new cluster is ready and verified first).

Time: recovery of a small database plus verification is normally well under an hour.

## Tier B — the NVMe dies, the host and the HDD mirror survive

This is the tier to rehearse. The HDD mirror (`backup` pool) holds the PBS datastore; the Proxmox
install, the VMs and the PBS configuration on the root disk do not survive. **Do not initialize,
partition or re-create the `backup` pool.** Import it.

1. **Protect the evidence and the mirror.** Do not boot an installer that offers to wipe disks.
   Confirm the two HDDs are present and healthy before touching anything
   (`lsblk`, `smartctl -a /dev/sdX`).
2. **Reinstall Proxmox on a new NVMe.** Private runbook `server-setup.md` sections 0–5: BIOS, ZFS
   root, host config, networking. Leave the HDDs alone.
3. **Import the backup pool and mount the datastore path.**
   `zpool import backup` (the pool name from `server-setup.md` section 4), then confirm the dataset
   is mounted (`zfs list`, `zpool status -x` = `pool is healthy`). If ZFS refuses to import, do not
   force it before checking `zpool import` output: a missing device is a different failure.
4. **Recreate PBS, reusing the existing datastore.** Run the Ansible `pbs` role
   (`ansible-playbook pve-host.yml --tags pbs`). When the datastore path already holds a chunk store
   the role creates the datastore with `--reuse-datastore`, never initializes it; on a fresh path it
   creates normally. The PBS user/token and their ACL are recreated by the role; the token secret is
   created once from the owner's terminal and goes straight into 1Password. Then apply
   `live/onprem-vm` (owner) so the PVE storage `pbs-qnsc` and the nightly backup job point at it
   again. Verify before restoring: `pvesm list pbs-qnsc` lists the old snapshots.
5. **Restore the VMs in order.** List the snapshots, pick the newest good one per VM
   (`pvesm list pbs-qnsc --vmid 100`), then restore to the real ids:
   `qmrestore <datastore>:backup/vm/<id>/<timestamp> <id> --storage local-zfs`
   (add `--force` only when a leftover VM with that id exists). Order: **100 (k3s-01), 101 (ai-01),
   102 (vlsi-01)** — the server first, then the agents.

   **Apply the VM-rollback rule (ONPREM-PLAN §10.5) before the restored k3s starts the databases.**
   The restored `pg-rova`/`pg-opshub` are up to 24 h stale and must not run against the live `g1`
   archive: keep VM 100 off the network, stop k3s (or delete the two `Cluster` resources and their
   PVCs from the restored guest), and only then let it join the network. The precise sequence is
   §10.5; do not skip it because the restore "looks fine".
6. **Bring the database to the RPO.** The PBS snapshot is up to 24 h old. With the old clusters
   removed, recover from R2 as a **new generation** (`serverName: pg-rova-g2`, `pg-opshub-g2`) —
   the Tier A procedure. The restored clusters' PVCs are deleted, not reused; the new cluster must
   pass its restore test before product traffic returns. If R2 is also gone, the restored PBS data
   is the recovery point and the dumps in `dumps/` are the second copy.
7. **Verify:** `kubectl get nodes` (3 Ready), ArgoCD all Healthy, `kubectl cnpg status` for both prod
   clusters, ESO stores Ready, product smoke tests, then a fresh PBS backup and a fresh dump
   (`DUMP-OK`).
8. **Write down the actual time** in the rehearsal log at the bottom. An RTO nobody measured is a
   guess.

Expected: 3–4 h, of which the Proxmox reinstall and the VM restores dominate.

## Tier C — the site from zero

Follow [`site-from-zero.md`](site-from-zero.md) rows 0–13. It already covers accounts/state, host
and ZFS, template 9000, `live/onprem-vm`, k3s, OIDC/identity, tunnels/DNS, Key Vault inputs, GitOps
bootstrap, data restore and verification. Budget one business day.

Two things that shorten C and are worth keeping true:
- every site value is in 1Password, so a new machine can run the same commands;
- the OIDC/JWKS trust root is republished by `live/onprem-oidc` + step 8, not copied from the dead
  host.

## Rehearsal: Tier B, restore VM 100 as VM 900 with the network unplugged

Purpose: prove the PBS snapshot of k3s-01 restores and boots, and measure RTO_B. No production
impact. Owner window; roughly 1–2 h including the restore.

1. **Pick the snapshot and check room.** `pvesm list pbs-qnsc --vmid 100`; choose the newest
   verified one. `zpool list` must show enough free space for the thin restore (VM 100 has a 120 G
   OS disk and a 1.2 T data disk; only allocated blocks are written).
2. **Restore as a new id, with new MACs:**
   `qmrestore <datastore>:backup/vm/100/<timestamp> 900 --storage local-zfs --unique`.
   `--unique` avoids colliding with the live VM's MAC addresses.
3. **Unplug the network before the first boot.** Read `net0` from `qm config 900`, then set it with
   `link_down=1` (keep the model/bridge/tag from the restored config; only add `link_down=1`).
   Confirm `qm config 900 | grep '^net0:'` shows `link_down=1`.
4. **Change the identity inside the guest before it can join the cluster.** Start 900 with the link
   down, log in on the console, then:
   - `hostnamectl set-hostname k3s-01-restore-900`;
   - change the static address in the guest's netplan/cloud-init to an UNUSED spare address (not
     k3s-01's), so a later link-up cannot collide;
   - `qm shutdown 900`.
   This is the identity half of the "network unplugged" rule: a restored clone with the original
   hostname and IP is a duplicate node waiting for one link-up.
5. **Assert the link is still down before the final boot.** `qm config 900 | grep '^net0:'` must
   contain `link_down=1`; if it does not, set it again and re-check. Then `qm start 900`.
6. **Verify locally:** console login, `systemctl --failed`, the root filesystem and
   `/var/lib/rancher/k3s/storage` mounted, `k3s` service state. It must **not** become a second
   Ready node: with the link down it cannot reach the API server. If `kubectl get nodes` shows
   900's hostname, stop it immediately — the link was not down.
7. **Record timestamps** T0 (qmrestore start), T1 (restore complete), T2 (first boot), T3 (verified
   checks). RTO_B = T3 − T0.
8. **Clean up:** `qm stop 900`, `qm destroy 900`. Remove nothing else: VM 900 is not in the backup
   job. If the restored VM's disks were thin, destroying it returns the space.

Do this once now, then once a year or after any change to PBS, the backup job or the VM layout.

### Rehearsal record

| Date | Snapshot used | T0 | T3 | RTO_B | Result / notes | By |
|---|---|---|---|---|---|---|
| _not yet rehearsed_ | | | | | | |
