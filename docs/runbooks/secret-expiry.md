# Secret and credential expiry: the weekly watch and the one-time backfill

Two things, one owner: the scheduled check that warns before something expires, and the backfill
that gives the Key Vault secrets which have no `expires` one where that is meaningful.

## The weekly watch

`.github/workflows/secret-expiry.yml` runs every Monday 02:17 UTC (09:17 ICT) on `main`, with the
existing **read-only** CI identity (`AZURE_CLIENT_ID_READ`):

- **Key Vault** — `az keyvault secret list` on `kv-qnsc-prod`, `kv-qnsc-platform`, `kv-qnsc-dev`.
  Key Vault Reader returns `attributes.exp`, never a value.
- **Entra** — `GET /applications` (Directory Readers) for `passwordCredentials` and `keyCredentials`
  end dates. Metadata only: `keyId`, display name, dates; no secret value.

| Result | Meaning | What happens |
|---|---|---|
| **FAIL** | a prod/platform secret has no expiry; or any credential is expired or has no readable end date | run is red, Teams card, run summary |
| **WARN** | anything expires within 30 days; or a dev secret has no expiry yet | run stays green, Teams card, run summary |
| **COULD NOT RUN** | a vault or Graph call failed (exit 2) | run is red, Teams card — never read as clean |

Identifiers stay without an expiry on purpose: `*-mcp-access-aud` (Cloudflare Access AUD tag),
`*-client-id` and `*-platform-admin-emails` (not credentials). `*-graph-cert` must use the
certificate's own end date.

Run it by hand: Actions → **Secret and credential expiry** → Run workflow. Locally, with an
`az login` that can read the vaults:

```sh
python3 scripts/secret_expiry.py --markdown /tmp/expiry.md --json /tmp/expiry.json
```

## The one-time backfill (owner)

The audit found 17 Key Vault secrets without `expires`: prod `rova-prod-app`,
`rova-prod-graph-cert`, `opshub-prod-graph-cert`, `rova-prod-mcp-access-aud`; platform's three
`argocd-*`; dev's ten `kb-dev-*`, two `*-graph-cert` and `rova-dev-mcp-access-aud`.

`scripts/owner/backfill-kv-expiry.sh` lists what it would set and writes nothing without `--apply`.
Non-certificate secrets require an EXPLICIT date — there is no blanket "+1 year":

```sh
az login --tenant <tenant>.onmicrosoft.com         # Key Vault Secrets Officer on each vault
scripts/owner/backfill-kv-expiry.sh --expires 2027-06-30              # plan
scripts/owner/backfill-kv-expiry.sh --expires 2027-06-30 --apply      # write
```

- `*-graph-cert` gets the certificate's end date: the Key Vault certificate object when one exists,
  otherwise the `notAfter` of the combined PEM that is stored as the secret (the graph-certs are
  secrets, not certificate objects). If neither is readable, the script stops rather than guess.
- Everything else uses the `--expires` value. Set it to the real vendor end date for that batch
  (R2 token, Entra client secret, GitHub App key); a later value hides the real deadline.
- The AUD/client-id/roster identifiers are skipped.
- A past date refuses to write (that is a rotation, not a backfill).

## Rotation

- Sign-in app client secrets: `scripts/rotate-signin-secret.sh` (creates the credential, writes the
  value to Key Vault, sets the same expiry).
- Key Vault values: `gitops platform/bootstrap/secrets.sh --force <name>` (owner, stdin only).
- After either, the next Monday run should show the new date. A WARN under 30 days is the reminder;
  an expired credential is a FAIL and, for ESO-synced values, an application outage.
