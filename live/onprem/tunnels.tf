# ── The two Tunnels and their ingress (ONPREM-PLAN §5.3, §8.2) ──────────────
#
# The in-cluster cloudflared Deployment only runs `tunnel run` with the token;
# ALL routing lives here, remotely managed. One rule per host + path; the
# keep-alive chain (§5.3) requires cloudflared → origin idle 60 s, strictly
# less than Node's 65 s / uvicorn's 65 s, so no request lands on a socket the
# origin is closing.
#
# The one host per app (§8.2): a Worker serves the SPA at the edge; the API
# paths BELOW are "no-Worker routes" — Workers routes in live/edge negate them,
# and they fall through to this Tunnel and straight to the Service. The browser
# sees one origin: no CORS, no cross-site cookies, CF-Connecting-IP is
# trustworthy because the origin has no other door.
#
# Service names are the CHART's services keys (charts/qnsc-service
# templates/service.yaml: `name: {{ $name }}`): the origin for a product's api
# is `api.<product>-<env>.svc:<port>` — NOT <product>-api.
#
# `path` is a REGEX (cloudflared ingress matching), anchored here on purpose:
# a broad pattern silently widens what bypasses Access.
#
# The catch-all is the LAST rule with no hostname — anything unmatched gets
# 404 at Cloudflare's edge, never a connection attempt at an origin.
#
# CI identity (plan/drift/apply) already exists; the remaining prerequisite
# is the Cloudflare token scope (Account > Cloudflare Tunnel > Edit) — see
# the README.

locals {
  qnsc_apps_ingress = [
    # rova prod — the only prod app; Access is NOT in front of prod (§8.2)
    { hostname = "rova.qnsc.vn", path = "^/api/auth/", service = "http://api.rova-prod.svc:3000" },
    { hostname = "rova.qnsc.vn", path = "^/v1/", service = "http://api.rova-prod.svc:3000" },
    { hostname = "rova.qnsc.vn", path = "^/readyz$", service = "http://api.rova-prod.svc:3000" },

    # rova dev — one Access app on the host (live/edge); the webhook bypass
    # lives in live/edge too, this file only routes what reaches the origin
    { hostname = "rova-dev.qnsc.vn", path = "^/api/auth/", service = "http://api.rova-dev.svc:3000" },
    { hostname = "rova-dev.qnsc.vn", path = "^/v1/", service = "http://api.rova-dev.svc:3000" },
    { hostname = "rova-dev.qnsc.vn", path = "^/readyz$", service = "http://api.rova-dev.svc:3000" },

    # opshub dev
    { hostname = "opshub-dev.qnsc.vn", path = "^/api/auth/", service = "http://api.opshub-dev.svc:3000" },
    { hostname = "opshub-dev.qnsc.vn", path = "^/v1/", service = "http://api.opshub-dev.svc:3000" },
    { hostname = "opshub-dev.qnsc.vn", path = "^/readyz$", service = "http://api.opshub-dev.svc:3000" },

    # kb dev — everything under /api (incl. /api/v1/auth/entra/callback) plus
    # /readyz, the alias of /health/ready that Synthetic Monitoring probes
    { hostname = "kb-dev.qnsc.vn", path = "^/api/", service = "http://api.kb-dev.svc:8000" },
    { hostname = "kb-dev.qnsc.vn", path = "^/readyz$", service = "http://api.kb-dev.svc:8000" },
  ]
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "qnsc_apps" {
  account_id = var.cloudflare_account_id
  name       = "qnsc-apps"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "qnsc_apps" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.qnsc_apps.id

  config = {
    # §5.3 — the default for every rule: 60 s idle. Shorter than the Node
    # (65 s) and uvicorn (65 s) origins behind it; the chain must DESCEND
    # towards the origin or a deploy races a dying socket.
    origin_request = {
      keep_alive_timeout = 60
    }

    ingress = concat(
      [for r in local.qnsc_apps_ingress : {
        hostname       = r.hostname
        path           = r.path
        service        = r.service
        origin_request = {}
      }],
      [
        # the catch-all — no hostname, always last
        {
          hostname       = null
          path           = null
          service        = "http_status:404"
          origin_request = {}
        },
      ]
    )
  }
}

# ── qnsc-admin — door 2 for the OPERATOR, not for apps ──────────────────────
#
# Runs as a systemd service on pve01 (not in k3s), so the host stays reachable
# (Proxmox UI, PBS, NUT) even when the cluster is the thing that is broken.
# Two public hostnames (admin_hostnames CI variable — never literal in this
# public repo; real values recorded in product-docs runbook §12.1) gated by
# Cloudflare Access + Entra + amr=mfa (§7.2; Access apps in live/edge), plus
# private-network
# routing for WARP + kubectl/SSH (§12.1). The Access app must exist BEFORE the
# first apply turns the hostnames on (runbook §12.1: Access first, hostname
# second). Interim MFA until FIDO2 keys arrive: Security Defaults +
# Authenticator still satisfies amr=mfa.
resource "cloudflare_zero_trust_tunnel_cloudflared" "qnsc_admin" {
  account_id = var.cloudflare_account_id
  name       = "qnsc-admin"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "qnsc_admin" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.qnsc_admin.id

  config = {
    ingress = [
      # §12.1 (runbook): the operator doors. Access apps on BOTH hosts are
      # owned by live/edge (Allow grp-qnsc-platform-admins, Require amr=mfa);
      # these rules only decide where an authenticated request lands. Order
      # matters: host rules BEFORE the catch-all.
      {
        hostname = var.admin_hostnames["pve"]
        path     = null
        service  = "https://localhost:8006"
        origin_request = {
          no_tls_verify = true # Proxmox pveproxy ships a self-signed cert
        }
      },
      {
        hostname = var.admin_hostnames["pbs"]
        path     = null
        service  = "https://localhost:8007"
        origin_request = {
          no_tls_verify = true # PBS ships a self-signed cert
        }
      },
      {
        hostname       = null
        path           = null
        service        = "http_status:404"
        origin_request = {}
      },
    ]
  }
}

# The private route that lets WARP-joined laptops reach pve01 through the
# admin tunnel.
resource "cloudflare_zero_trust_tunnel_cloudflared_route" "qnsc_admin_lan" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.qnsc_admin.id
  network    = var.admin_private_cidr
  comment    = "office LAN via pve01"
}

# ── NOT in this stack yet (Phase 1, same directory, own PRs) ────────────────
# stqnscbackup (Azure): the storage account with locked immutability + lifecycle
#   (§10.3). Written once the subscription exists.
# (qnsc-backups lives in backups.tf since M-6.)
# TOKENS: the tunnel resources keep NO secret in state, and the provider's
# tunnel-token data source is NEVER used (it would pull the token into
# plan/state). After apply the owner reads each token —
# GET /accounts/{account_id}/cfd_tunnel/{id}/token — and pipes it through
# stdin: qnsc-apps into kv-qnsc-platform (platform-cloudflared-qnsc-apps,
# ESO-synced), qnsc-admin into kv-qnsc-admin (admin-cloudflared-qnsc-admin,
# → pve01 /etc/cloudflared/qnsc-admin.env). This stack creates the doors;
# it never stores keys.
