# Secret and credential expiry: the weekly watch and the one-time backfill

Two things, one owner: the scheduled check that warns before something expires, and the backfill
that gives the Key Vault secrets which have no `expires` one where that is meaningful.

## The weekly watch

`.github/workflows/secret-expiry.yml` runs every Monday 02:17 UTC (09:17 ICT) on `main`, with the
existing **read-only** CI identity (`AZURE_CLIENT_ID_READ`):

- **Key Vault** — `az keyvault secret list` on `kv-qnsc-prod`, `kv-qnsc-platform`, `kv-qnsc-dev`.
  Key Vault Reader returns `attributes.exp`, never a value. The estate's certificates
  (`*-graph-cert`) are stored as SECRETS, not certificate objects, so this list is the complete
  cert coverage; a future certificate object would also surface as its backing secret.
- **Entra** — `GET /applications` (Directory Readers) for `passwordCredentials` and `keyCredentials`
  end dates. Metadata only: `keyId`, display name, dates; no secret value. It is every app
  registration, not a name filter: the product `*Prod`/`*Dev` sign-in apps, the `*Service` apps,
  the ESO apps and anything hand-made are all covered — a new app needs no watcher change.

| Result | Meaning | What happens |
|---|---|---|
| **FAIL** | a prod/platform secret has no expiry; or any credential is expired, expires within 7 days, or has no readable end date | run is red, Teams card (with an `URGENT (<=7d or expired)` count), run summary |
| **WARN** | anything expires within 30 days; or a dev secret has no expiry yet | run stays green, Teams card, run summary |
| **COULD NOT RUN** | a vault or Graph call failed (exit 2) | run is red, Teams card — never read as clean |

The two thresholds are deliberate: 30 days is the rotation window, 7 days fails the run because a
weekly check would otherwise get one more shot after the credential is already gone.

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

## Pruning the unreferenced secrets (2026-11-06 audit)

TWO secrets had no consumer left:

| Vault | Secret | Why it is safe |
|---|---|---|
| `kv-qnsc-dev` | `kb-dev-app` | legacy JSON bundle; the chart dropped `secrets.bundle` when kb moved to per-value env |
| `kv-qnsc-prod` | `rova-prod-app` | same legacy bundle shape |

**`kv-qnsc-admin/platform-cnpg-ca-dev` is NOT a candidate.** Its name is CONSTRUCTED in gitops
(`platform/bootstrap/cluster.sh`: `platform-cnpg-ca-$ENV`) and `platform/bootstrap/secrets.sh`
mints a NEW CA whenever the secret is absent — deleting it would silently replace the dev CA and
break every existing dev CNPG cluster's trust chain. The kill switch mutates; keep the secret.

`scripts/owner/prune-kv-secrets.sh` is the owner's tool. It greps the COMMITTED `origin/main`
tree of this repo and of gitops (git fetch + git archive, never the working checkout) and, with
`--with-products` or `--apply`, fresh shallow clones of rova, opshub, qnsc-kb-backend and
qnsc-kb-frontend. Every hit is classified: a code/config reference BLOCKS all deletion; a
documentation, test-fixture or comment mention does not. ANY reference stops the run with nothing
deleted — including when every candidate is referenced. Dry run by default:

```sh
scripts/owner/prune-kv-secrets.sh --gitops ../gitops                      # proof (infra + gitops)
scripts/owner/prune-kv-secrets.sh --gitops ../gitops --with-products      # + the four product repos
scripts/owner/prune-kv-secrets.sh --gitops ../gitops --apply              # soft-delete the proven ones
```

The delete is a SOFT delete — Key Vault keeps the secret for 90 days and it can be recovered
(`az keyvault secret recover`). The script never purges. Its offline test runs in CI
(`scripts/owner/prune-kv-secrets_test.sh`).

### Expiry on what IaC owns

This stack creates NO Key Vault secret values — there is no `azurerm_key_vault_secret` anywhere in
the tree, by design (§7: OpenTofu owns shape and access, never values). So an expiry can only be a
set of owner actions through `scripts/owner/backfill-kv-expiry.sh`; no code change sets one. The
credentials the identity lane OWNS (`*-graph-cert`) take the certificate's own `notAfter`, which the
backfill script reads; everything else is a vendor deadline the owner supplies with `--expires`.

### Still without an expiry (owner list)

The audit counted 28 BEFORE the prune. BOTH `kb-dev-app` and `rova-prod-app` are deleted above, so
expect 26 once the script has run. The live dry run of the backfill is authoritative — this is the
audit's list, minus the two pruned names:

- **prod (5 after the prune)**: `kb-prod-graph-cert`, `opshub-prod-graph-cert`, `rova-prod-graph-cert`,
  `rova-prod-mcp-access-aud`, `rova-prod-mcp-idempotency-secret`;
- **platform (4)**: the argocd `grafana-token`, `grafana-url`, `teams-webhook`, `webhook-secret`;
- **dev (18)**: all ten `kb-dev-*`, `opshub-dev-db-readonly`, `opshub-dev-graph-cert`,
  `r2-backup-dev-rw-*` (2), `rova-dev-db-readonly`, `rova-dev-graph-cert`, `rova-dev-mcp-access-aud`,
  `rova-dev-mcp-idempotency-secret`.

Several also lack the `owner` tag (`kb-dev-db-*`, the `*-db-readonly`, `r2-backup-dev-rw-*`, the
`*-mcp-*`, argocd grafana/teams, `admin-cloudflared-qnsc-admin`). Add it in the same pass.
Identifiers that never rotate (`*-mcp-access-aud`, `*-client-id`, the platform-admin roster) stay
without an expiry on purpose.

## Rotation

- Sign-in app client secrets: `scripts/rotate-signin-secret.sh` (creates the credential, writes the
  value to Key Vault, sets the same expiry).
- Key Vault values: `gitops platform/bootstrap/secrets.sh --force <name>` (owner, stdin only).
- After either, the next Monday run should show the new date. A WARN under 30 days is the reminder;
  an expired credential is a FAIL and, for ESO-synced values, an application outage.
