# KB Dev: split the cluster's sign-in secret from the laptop credential

The in-cluster KB Dev API and worker sign in with the **KB Dev** Entra app.
Today the app has ONE credential, named `QNSC local development`, and the
cluster reads that same value from `kv-qnsc-dev/kb-dev-microsoft-client-secret`.
Developer laptops use the same credential, so one leak or one rotation breaks
both, and the vault entry has no expiry for the expiry watch to see
(2026-11-06 drift audit, Med).

This runbook gives the cluster its OWN credential. The ESO key does not change:
the new value replaces the old one under `kb-dev-microsoft-client-secret`, so
nothing in gitops is edited.

## What is where

| Piece | Name | Where |
|---|---|---|
| Entra app | `KB Dev` | app registration, object id from `az ad app list --filter "displayName eq 'KB Dev'"` |
| Live credential | `QNSC local development` | expires **2027-01-30** (the earliest in the tenant) |
| Vault secret | `kb-dev-microsoft-client-secret` | `kv-qnsc-dev`; today **no expiry / no owner tag** |
| ESO | `ExternalSecret/kb-env` | namespace `kb`, ClusterSecretStore `kv-qnsc-dev`, `refreshInterval: 1h`; renders env `MICROSOFT_CLIENT_SECRET` into the `kb-env` Secret |
| Consumers | `Deployment/api`, `Deployment/worker` (not `web`) | namespace `kb` |

## Prerequisites (decide BEFORE revoking anything)

The cluster stops using the old credential when the vault value changes. The
laptops do not: they hold a copy of the `QNSC local development` value.

- Give each laptop its own credential (create it in Entra, distribute through
  1Password, never in Git), **or** move local KB development to the loopback
  flow so a laptop holds no client secret at all.
- Only when no laptop uses the old value may step 4 revoke it.

## Cutover (owner, `az login` in your own terminal)

1. Record the app object id and the OLD credential's keyId, so a rollback and
   the final revocation name the right object:

   ```sh
   # Exactly one app, or STOP. `[0]` would silently rotate a duplicate's
   # credential: the kit's fetch_app uses the same length(@)==1 rule. The
   # guard returns non-zero, so the credential list below it never runs on a
   # duplicate (or a missing app).
   kb_dev_creds() {
     local count
     count=$(az ad app list --filter "displayName eq 'KB Dev'" --query 'length(@)' -o tsv)
     if [ "$count" != "1" ]; then
       echo "STOP: expected exactly one app named 'KB Dev', found $count" >&2
       return 1
     fi
     KB_DEV_APP=$(az ad app list --filter "displayName eq 'KB Dev'" --query '[0].id' -o tsv)
     az ad app credential list --id "$KB_DEV_APP" \
       --query '[].{keyId:keyId,name:displayName,expires:endDateTime}' -o table
   }
   kb_dev_creds
   ```

2. Create the cluster's credential and land it in the ESO key. This is the
   existing rotation script: it APPENDS a new credential (+6 months), writes
   its value straight into the vault with `--expires` and owner tags, and
   never prints the value. The old credential keeps working.

   ```sh
   scripts/rotate-signin-secret.sh "$KB_DEV_APP" kv-qnsc-dev kb-dev-microsoft-client-secret
   ```

   The new credential's keyId is printed to stderr; keep it as the handle
   for a rollback.

3. Pull the new value into the cluster. Force the ExternalSecret rather than
   waiting for its 1-hour refresh, then restart the two deployments that read
   it:

   ```sh
   kubectl -n kb annotate externalsecret kb-env force-sync="$(date +%s)" --overwrite
   kubectl -n kb wait --for=condition=Ready externalsecret/kb-env --timeout=2m
   kubectl -n kb rollout restart deployment/api deployment/worker
   kubectl -n kb rollout status  deployment/api deployment/worker
   ```

4. Verify before revoking anything:

   - Open `https://kb-dev.qnsc.vn`, sign in through Cloudflare Access / Entra.
   - Exercise a Graph-backed connector (the worker's `AZURE_CLIENT_CERTIFICATE_PATH`
     path is separate; this is about `MICROSOFT_CLIENT_SECRET`).
   - In `kubectl -n kb logs deployment/api`, there must be no
     `AADSTS7000215` (invalid client secret) or token-refresh errors.

5. Revoke the old credential. **This is irreversible and it is the step that
   breaks any laptop still holding the old value** — do it only after the
   prerequisites above and a green step 4.

   ```sh
   az ad app credential delete --id "$KB_DEV_APP" --key-id <old keyId from step 1>
   ```

6. Confirm the vault entry now carries an expiry (the weekly watch reads it):
   `az keyvault secret show --vault-name kv-qnsc-dev --name kb-dev-microsoft-client-secret --query 'attributes.expires'`

## Rollback

The old credential is valid until step 5. Before that, re-running
`scripts/rotate-signin-secret.sh` with the same arguments adds another
credential and points the vault at it; the cluster picks it up at the next ESO
refresh or forced sync. After step 5 a rollback means creating a new
credential the same way — the old value is gone.

## Follow-ups this runbook does not cover

- The laptop story (own credential or loopback-only flow) is the prerequisite.
- The credential lives outside Terraform by design (§7); `live/identity` owns
  the app shape, never the value.
