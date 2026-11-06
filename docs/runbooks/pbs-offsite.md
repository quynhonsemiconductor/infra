# PBS: client-side encryption, the off-site copy, and the restore drill

Two decisions from 2026-11-04, done together because one is useless without the other: **encrypt the VM
backups** (only worth it once a copy leaves the machine) and **keep a weekly copy off the host** (only safe
once the copy is ciphertext — the sync copies **only encrypted snapshots**, so the pre-cutover ones never
leave the host). The local PBS stays the fast restore path; this page is about the copy that survives the site.

Public repo: no addresses, hostnames, bucket URLs, keys or tokens here. Site values live in the owner's
git-ignored `site.tfvars` / local Ansible inventory and in 1Password.

```
PVE  --(client-side encrypted)-->  PBS qnsc  --(weekly local sync)-->  PBS qnsc-offsite  -->  Cloudflare R2
      key: 1Password + paper + USB                                       (S3-backed datastore, cache on ZFS)
```

## 0. THE KEY — read this before anything else

The key encrypts every backup **before** it leaves the guest's backup process. PBS stores opaque chunks and
R2 stores the same opaque chunks.

> **Losing the key makes every encrypted backup unreadable. There is no recovery, no support path and no
> "PBS can still read it". The key exists in exactly three places: 1Password, a paper printout and a USB
> stick. If all three are lost, the backups are noise and the only remaining copy of the estate is the
> running host.**

Corollary: a restore — routine or in a disaster — needs the key file. Keep one copy where you can get it
without the host (1Password) and one where 1Password is unreachable (paper/USB in the safe).

### 0.1 Create the key once (owner, on pve01)

PVE supports only keys **without** a KDF/passphrase, and it keeps the key in its own config — **the key is
never a Terraform input**, so it cannot reach the OpenTofu state.

### 0.1 Create and store the key (owner, root on pve01)

```sh
# 1. let PVE generate it (the documented generator; --kdf none semantics inside PVE)
pvesm set pbs-qnsc --encryption-key autogen
#    the key now lives in /etc/pve/priv/storage/pbs-qnsc.enc (root-only, mode 0600)

# 2. the offline-recovery form: base32 + QR on paper (two copies, different rooms)
proxmox-backup-client key paperkey /etc/pve/priv/storage/pbs-qnsc.enc \
  | tee /root/qnsc-pbs-key-paper.txt

# 3. the fingerprint: record it next to the key everywhere they live
proxmox-backup-client key show /etc/pve/priv/storage/pbs-qnsc.enc
```

1. Copy `/etc/pve/priv/storage/pbs-qnsc.enc` to the 1Password item **"PBS - backup encryption key"** (vault
   `QNSC`) as an attachment, with the fingerprint and the creation date in the item's note.
2. Print the paperkey output: **two copies**, one in the office safe and one off-site; keep the printed
   fingerprint with them. The paperkey text in 1Password is the second copy.
3. Copy the key file to the USB stick that lives with the paper copy; label it with what it is and the date.
4. Delete `/root/qnsc-pbs-key-paper.txt`. Leave PVE's copy alone: it is the live one.

**A healthy host therefore holds a copy of the key** (`/etc/pve/priv/storage/pbs-qnsc.enc`). Tiers A and B of
`dr.md` can restore on that host without 1Password. **Tier C cannot** — the key file died with the host — which
is exactly why the three offline copies exist.

Check: the OpenTofu plan for `live/onprem-vm` must show **no change** on the storage — a `-/+` (replace) is
NO-GO at every apply. Set `pbs_encryption_required = true` in the git-ignored `site.tfvars` (default false, so
every other plan keeps working): from then on the plan fails with "pbs-qnsc has no client-side encryption key"
whenever the storage lost its key (a `terraform_data` guard reads the storage's read-only
`encryption-key-fingerprint`).

The key must also be absent from the state. It is never a TF input; the check greps the state for the key's own
base64 material (the PVE key file is JSON, so `grep` on the file would match nothing):

```sh
cd live/onprem-vm
KEY_DATA="$(jq -r .data /etc/pve/priv/storage/pbs-qnsc.enc)"
tofu state pull | grep -qF -- "$KEY_DATA" \
  && { echo "STOP: key material found in state"; exit 1; } || echo "key not in state"
tofu state show proxmox_storage_pbs.pbs_qnsc | grep -E '^[[:space:]]*encryption_key[[:space:]]*=' \
  && { echo "STOP: encryption_key attribute in state"; exit 1; } || echo "no encryption_key attribute"
``` A `-/+` (replace) on `proxmox_storage_pbs.pbs_qnsc` is **NO-GO** at every
apply: it would deregister the storage and the key with it.

The next nightly backup is encrypted. Snapshots taken before this moment are **not**. They stay restorable
without the key and age out on the prune schedule (7 daily / 4 weekly / 6 monthly), **and the off-site sync
skips them** (`--encrypted-only`, §2): a readable image never leaves the host. Record the cutover date in
1Password — a restore of anything older needs no key, anything newer does.

Verify after the first encrypted run:

```sh
proxmox-backup-client snapshot list --repository backup@pbs@127.0.0.1:qnsc \
  --keyfile /etc/pve/priv/storage/pbs-qnsc.enc
#   (the PVE side: the nightly task log says `encryption: encrypted`)
```

## 1. The off-site bucket and its token (owner)

The bucket is **infra** (`live/onprem/backups.tf`, `qnsc-pbs-offsite`): plain R2 in `apac`, **no Object
Lock, no versioning** — PBS documents both as the quickest way to corrupt an S3 datastore, and immutability
comes from the sync job never propagating deletions instead.

The token is **not** IaC (Cloudflare has no API for minting tokens):

1. Dashboard → **R2 → Manage R2 API Tokens → Create API token**, name `pbs-offsite-sync`:
   - Permissions: **Object Read & Write**;
   - Bucket scope: **Only `qnsc-pbs-offsite`** (never account-wide);
   - TTL: none (a sync job runs forever); rotate by creating a replacement and re-running the Ansible run
     with the new keys.
2. Store the **Access Key ID** and **Secret Access Key** in 1Password as the item
   **"PBS - R2 off-site sync"**, and add the R2 S3 endpoint (`<account-id>.r2.cloudflarestorage.com`) to the
   local Ansible inventory as `pbs_offsite_endpoint_host`.

## 2. Turn on the off-site copy (owner, `ansible/`)

The role is off by default (`pbs_offsite_enabled: false`). It asserts PBS **4.2 or newer** first (S3
datastores; the sync flag below needs 4.0+), then creates, in order: the cache dataset (`backup/pbs-cache`,
quota 128 GiB — PBS requires a local cache for an S3 datastore), the S3 endpoint (path-style, `region auto`,
R2), the S3-backed datastore `qnsc-offsite`, a weekly **verify job** for it, and the weekly **local** sync job
`qnsc-offsite-weekly` (`Sun 05:00`, source `qnsc`, **`--encrypted-only true`**, no deletions propagated).

`--encrypted-only` is what keeps the pre-2026-11-06 unencrypted snapshots (still in `qnsc` for up to six
months) from ever reaching R2: they are skipped, not published. Check the sync task log for "skipped"
lines after the first run — a VM that backs up WITHOUT encryption would be skipped silently.

```sh
cd ansible
export PBS_S3_ACCESS_KEY="$(op read 'op://QNSC/PBS - R2 off-site sync/access key id')"
export PBS_S3_SECRET_KEY="$(op read 'op://QNSC/PBS - R2 off-site sync/secret access key')"

op run --env-file=<local template> -- \
  ansible-playbook pve-host.yml --tags pbs_offsite --check --diff \
  -e pbs_offsite_enabled=true -e pbs_offsite_endpoint_host=<account-id>.r2.cloudflarestorage.com

# review, then the same without --check / --diff
```

Notes:

- The first sync copies **every** snapshot that is not already there: expect hours on a WAN link and a
  first-month R2 bill that is larger than the steady state. Throttle with `--rate-out` on the endpoint if
  the upload starves the VMs.
- Sync copies the encrypted chunks as they are: a key that is lost **after** a sync loss is still fatal, so
  the key drill in §0 is not optional.
- PBS 4.2 or newer is required for S3 datastores (`proxmox-backup-manager --version`).

Verify after the first run:

```sh
proxmox-backup-manager sync-job show qnsc-offsite-weekly | grep -i encrypted   # encrypted-only: true
proxmox-backup-manager datastore list                     # qnsc-offsite, used > 0
proxmox-backup-manager snapshot list qnsc-offsite --output-format json | jq length
proxmox-backup-manager verify-job list                    # qnsc-offsite-verify, weekly
# the sync task log: skipped snapshots are the unencrypted ones (expected until they are pruned)
ls -t /var/log/proxmox-backup/tasks/ | head
```

### 2.1 R2 token rotation

The endpoint's credentials live in PBS's own config. The role compares a hash of the two values with
`/etc/pbs-offsite-endpoint.sha256` and runs `s3 endpoint update` when they differ, so rotation is:

1. create the replacement R2 token (same scope), store it in 1Password;
2. re-run the same `ansible-playbook … --tags pbs_offsite` with the new `PBS_S3_ACCESS_KEY` /
   `PBS_S3_SECRET_KEY` — the changed hash triggers the update, and it prints that it did;
3. run a sync by hand (`proxmox-backup-manager sync-job run qnsc-offsite-weekly`) to prove the new token;
4. revoke the old token in the dashboard.

## 3. The restore drill (run once a quarter, 30-45 minutes)

**From the OFF-SITE datastore, on the same PBS** (the S3 cache serves the chunks; this drills the R2 copy
and the key, not the local one):

1. List the snapshots in the OFF-SITE datastore with the PBS client (there is no PVE storage for it — the
   only PVE storage is `pbs-qnsc`, which points at the local datastore):

   ```sh
   proxmox-backup-client snapshot list --repository backup@pbs@127.0.0.1:qnsc-offsite \
     --keyfile /etc/pve/priv/storage/pbs-qnsc.enc
   ```

   Pick the newest `vm/102` (`vlsi-01`, the least critical — a wrong restore costs nothing). The key file is
   the host's own copy; from a rebuilt host use 1Password's, which is the point of the drill.

2. `qmrestore` needs a PVE storage, so register the off-site datastore **temporarily** (the owner's PBS token
   is the same one `live/onprem-vm` uses, in 1Password) and restore to a **scratch id** (1999):

   ```sh
   read -rs PBS_TOKEN
   pvesm add pbs pbs-qnsc-offsite-tmp --server 127.0.0.1 --datastore qnsc-offsite \
     --username 'backup@pbs!pve' --password "$PBS_TOKEN" --content backup --fingerprint <pbs fingerprint>
   unset PBS_TOKEN

   qmrestore --storage local-zfs --unique \
     "pbs-qnsc-offsite-tmp:backup/vm/102/<timestamp>" 1999 \
     --keyfile /etc/pve/priv/storage/pbs-qnsc.enc

   pvesm remove pbs-qnsc-offsite-tmp     # after the drill, always
   ```

   `--unique` refuses to overwrite an existing VM; `--keyfile` is the whole point — without it the restore
   fails with "encryption key required". A registered storage that is forgotten is the one side effect of this
   drill, so `pvesm remove` is part of the step, not an afterthought.

3. Boot it **without a network device** (`qm set 1999 --delete net0` — or take the NIC down in the guest on
   first boot) so a stale k3s agent cannot join the cluster. Check it starts and the guest agent answers
   (`qm guest cmd 1999 get-osinfo`), which proves the image and the key, not the product.
4. Destroy the scratch VM: `qm stop 1999 && qm destroy 1999`, and delete nothing else.
5. Log the drill: date, snapshot timestamp used, key fingerprint, who ran it. Keep the log next to the
   paper key — a drill you cannot prove is a drill nobody did.

**Failure means stop and fix before the next backup cycle:**

| Symptom | Meaning |
|---|---|
| `encryption key required` / cannot open | the key you have is not the key the backup was made with — compare fingerprints with §0.1 and 1Password |
| `config does not exist` / snapshot list is short | the sync job is not running: `proxmox-backup-manager sync-job list`, then the PBS task log (`/var/log/proxmox-backup/tasks/`) |
| Restore works from `qnsc` but not `qnsc-offsite` | the off-site store never received that snapshot (sync after the backup? check the schedule) — the local copy is the restore source until it catches up |

## 4. Where this sits in the disaster tiers

### Accepted risk: a compromised pve01 can delete the off-site copy

The R2 token is Object Read & Write on `qnsc-pbs-offsite`, and it lives on the host (PBS config) that runs the
sync. Anyone who owns pve01 can therefore delete the off-site snapshots as easily as the local ones. Object
Lock is **not** an option: PBS rewrites its own index objects and the docs name Object Lock and versioning as
the fastest way to corrupt an S3 datastore. What is left is a copy that survives **host and disk loss** — the
realistic failure, and the one `dr.md` rehearses — but not an attacker with root. A later option, if that
matters: a SECOND bucket with Object Lock (no PBS on it) receiving a monthly `rclone copy` of the datastore,
which is a plain object copy and never a datastore in use.

`dr.md` has the full picture. In one line: tier A and B restore from the local PBS as before (now with
`--keyfile`); tier C — the host and the HDD mirror are both gone — restores from this bucket: build a PBS on
any machine, create the `qnsc-offsite` datastore against the bucket with the same endpoint and cache path,
put the key in place, and `qmrestore` from it. That path is why the bucket is in a different provider from
the host and why the key lives outside both.
