# live/onprem

The on-prem doors: the two Cloudflare Tunnels (`qnsc-apps`, `qnsc-admin`),
their remotely-managed ingress config, and the backup targets.
**Skeleton — applies nothing yet**: no state backend (no subscription) and no
Cloudflare token with Tunnel scope.

## Owns

- `qnsc-apps` — the app door. One ingress rule per host + path (the API paths
  of §8.2), `origin_request.keep_alive_timeout = 60` (§5.3: strictly below the
  Node 65 s / uvicorn 65 s origins), final catch-all `http_status:404`.
  The Worker/SPA routes and Access apps are live/edge's half of the same
  design; this file routes what falls through to the origin.
- `qnsc-admin` — the operator door, systemd on pve01, private-network route to
  the office LAN only, gated by Access + Entra `amr=mfa` in live/edge.
- Phase 1 (own PRs): `qnsc-backups` (R2, Bucket Lock + lifecycle) and
  `stqnscbackup` (Azure, locked immutability) — written once the accounts
  exist, never guessed from schema memory.

## Token handling

The tunnel resources keep NO secret in state (values never in state, §7).
After apply, the owner reads the tunnel token and pipes it into
`kv-qnsc-platform` as `platform-cloudflared-qnsc-apps` through stdin — never
argv, never logs. The in-cluster cloudflared runs `tunnel run` with the token
ESO syncs from that vault.

## Why no in-cluster ingress exists

There is no Gateway and no ingress controller on-prem. cloudflared routes
host + path STRAIGHT to Services. A second router behind the Tunnel is §9
work with its own trigger.
