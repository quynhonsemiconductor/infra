# live/onprem

The on-prem doors: the two Cloudflare Tunnels (`qnsc-apps`, `qnsc-admin`),
their remotely-managed ingress config, and the backup targets.
The state backend is wired (Azure: rg-qnsc-platform / stqnsctfstate / tfstate,
key infra/onprem/terraform.tfstate). The CI identities already exist: plan and
drift run as **QNSC CI Infra Read**, apply as **QNSC CI Infra** (each app
holds its federated credential and its Storage Blob Data roles on
stqnsctfstate). The only remaining blocker is the Cloudflare
token scopes — see "Token handling" below. The ADMIN_PRIVATE_CIDR and ADMIN_HOSTNAMES inputs are repo
SECRETS, never variables: variable values print unmasked in step env logs of
this public repo.

## Owns

- `qnsc-apps` — the app door. One ingress rule per host + path (the API paths
  of §8.2), `origin_request.keep_alive_timeout = 60` (§5.3: strictly below the
  Node 65 s / uvicorn 65 s origins), final catch-all `http_status:404`.
  The Worker/SPA routes and Access apps are live/edge's half of the same
  design; this file routes what falls through to the origin.
- `qnsc-admin` — the operator door, systemd on pve01, private-network route to
  the office LAN only, gated by Access + Entra `amr=mfa` in live/edge.
- `qnsc-backups` (R2, Bucket Lock + lifecycle) already lives in backups.tf.
- Phase 1 (own PR): `stqnscbackup` (Azure, locked immutability) — written
  once the storage account exists, never guessed from schema memory.

## Token handling

The tunnel resources keep NO secret in state (values never in state, §7).
NEVER use the provider's tunnel-token data source: it would pull the token
into plan/state.

- `qnsc-apps`: after apply, the owner reads the token —
  `GET /accounts/{account_id}/cfd_tunnel/{tunnel_id}/token` — and pipes it
  through stdin into `kv-qnsc-platform` as `platform-cloudflared-qnsc-apps`.
  The in-cluster cloudflared runs `tunnel run` with the token ESO syncs from
  that vault.
- `qnsc-admin`: same retrieval, piped through stdin into
  `kv-qnsc-admin` as `admin-cloudflared-qnsc-admin`; on pve01 the systemd
  service reads it from `/etc/cloudflared/qnsc-admin.env`.

Never argv, never logs.

## Why no in-cluster ingress exists

There is no Gateway and no ingress controller on-prem. cloudflared routes
host + path STRAIGHT to Services. A second router behind the Tunnel is §9
work with its own trigger.
