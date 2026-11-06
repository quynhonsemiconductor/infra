# PBS: client-side encryption, the off-site copy, and the restore drill

Two decisions from 2026-11-04, done together because one is useless without the other: **encrypt the VM
backups** (only worth it once a copy leaves the machine) and **keep a weekly copy off the host** (only safe
once the copy is ciphertext). The local PBS stays the fast restore path; this page is about the copy that
survives the site.

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

PVE supports only keys **without** a KDF/passphrase:

```sh
# as root on pve01; --kdf none is required, PVE refuses password-protected keys
proxmox-backup-client key create --kdf none /root/qnsc-pbs-encryption.key
chmod 600 /root/qnsc-pbs-encryption.key

# the offline-recovery form: base32 + QR on paper (two copies, different rooms)
proxmox-backup-client key paperkey /root/qnsc-pbs-encryption.key | tee /root/qnsc-pbs-key-paper.txt
```

1. Store the key FILE as a 1Password attachment on the item **"PBS - backup encryption key"** (vault
   `QNSC`), together with the paperkey text as the item's note and the creation date.
2. Print the paperkey output: **two copies**, one in the office safe and one off-site. Read one back with
   `proxmox-backup-client key paperkey --restore` (through the recovery flow in the PBS docs) if the file is
   ever lost — then put the file back in 1Password.
3. Copy the key file to the USB stick that lives with the paper copy, and write on the stick's label what it
   is and the date.
4. Only then delete `/root/qnsc-pbs-encryption.key` from pve01 — the OpenTofu apply below puts it into PVE's
   storage config (`/etc/pve/priv/storage/pbs-qnsc.enc`, root-only).

Check: `proxmox-backup-client key show /root/qnsc-pbs-encryption.key` prints the key's fingerprint. Record
the fingerprint in 1Password next to the item; the storage's `encryption-key-fingerprint` in PVE must match.

### 0.2 Turn it on (owner, laptop)

`live/onprem-vm` refuses to apply with an empty key (precondition on the storage):

```sh
export TF_VAR_pbs_encryption_key="$(op read 'op://QNSC/PBS - backup encryption key/key')"
tofu plan                                   # one in-place update on the pbs-qnsc storage
tofu apply tfplan
pvesm status -storage pbs-qnsc              # still active
```

The next nightly backup is encrypted. Snapshots taken before this moment are **not**, stay restorable
without the key, and age out on the prune schedule (7 daily / 4 weekly / 6 monthly — the last unencrypted
one is gone within six months). Record the cutover date in 1Password: a restore of anything older needs no
key, anything newer does.

Verify after the first encrypted run:

```sh
proxmox-backup-client snapshot list --repository backup@pbs@127.0.0.1:qnsc --keyfile /root/qnsc-pbs-encryption.key
#   (or from the PVE side: the task log of the nightly job says `encryption: encrypted`)
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

The role is off by default (`pbs_offsite_enabled: false`). It creates, in order: the cache dataset
(`backup/pbs-cache`, quota 128 GiB — PBS requires a local cache for an S3 datastore), the S3 endpoint
(path-style, `region auto`, R2), the S3-backed datastore `qnsc-offsite`, and the weekly **local** sync job
`qnsc-offsite-weekly` (`Sun 05:00`, source `qnsc`, no deletions propagated).

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
proxmox-backup-manager sync-job list
proxmox-backup-manager datastore list                     # qnsc-offsite, used > 0
proxmox-backup-manager snapshot list qnsc-offsite --output-format json | jq length
```

## 3. The restore drill (run once a quarter, 30-45 minutes)

**From the OFF-SITE datastore, on the same PBS** (the S3 cache serves the chunks; this drills the R2 copy
and the key, not the local one):

1. Pick the newest snapshot of VM 102 (`vlsi-01`, the least critical — a wrong restore costs nothing):

   ```sh
   proxmox-backup-manager snapshot list qnsc-offsite --output-format json \
     | jq -r '.[] | select(.backup-type=="vm" and .backup-id=="102") | "\(.backup-time) \(.size)"' | sort | tail -3
   ```

2. Restore it to a **scratch id** (1999) with the key, never over the real VM:

   ```sh
   qmrestore --storage local-zfs --unique \
     "qnsc-offsite:backup/vm/102/<timestamp>" 1999 \
     --keyfile <the key file from 1Password>
   ```

   `--unique` refuses to overwrite an existing VM; `--keyfile` is the whole point — without it the restore
   fails with "encryption key required".

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

`dr.md` has the full picture. In one line: tier A and B restore from the local PBS as before (now with
`--keyfile`); tier C — the host and the HDD mirror are both gone — restores from this bucket: build a PBS on
any machine, create the `qnsc-offsite` datastore against the bucket with the same endpoint and cache path,
put the key in place, and `qmrestore` from it. That path is why the bucket is in a different provider from
the host and why the key lives outside both.
