# ── The two Tunnels and their ingress (ONPREM-PLAN §5.3, §8.2) ──────────────
#
# The in-cluster cloudflared Deployment only runs `tunnel run` with the token;
# ALL routing lives here, remotely managed. One rule per host + path; the
# keep-alive chain (§5.3) requires cloudflared → origin idle 60 s, strictly
# less than Node's 65 s / uvicorn's 65 s, so no request lands on a socket the
# origin is closing.
#
# The one host per app (§8.2): the SPA is either a Worker at the edge or (P3, chart 0.18+) the in-cluster web
# component behind a host catch-all rule (`path = null`, LAST for its host: first match wins). Where it is a Worker, the API
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
    # /mcp: the rova-prod MCP Access app (Managed OAuth) is in front; cloudflared checks ITS JWT.
    { hostname = "rova.qnsc.vn", path = "^/mcp(/|$)", service = "http://api.rova-prod.svc:3000", access_app = "rova-prod MCP server" },

    # opshub prod (P3, owner decisions 2026-11-04): staff + MFA Access app on the host (live/edge, infra#343), SPA
    # from the cluster, no door terminal route at launch. Inert until edge publishes DNS for the host. The host
    # joins access_jwt_hosts in a follow-up, once its Access app exists (the data lookup needs it).
    { hostname = "opshub.qnsc.vn", path = "^/api/auth/", service = "http://api.opshub-prod.svc:3000" },
    { hostname = "opshub.qnsc.vn", path = "^/v1/", service = "http://api.opshub-prod.svc:3000" },
    { hostname = "opshub.qnsc.vn", path = "^/readyz$", service = "http://api.opshub-prod.svc:3000", bypass = true },
    { hostname = "opshub.qnsc.vn", path = null, service = "http://web.opshub-prod.svc:8080" },

    # kb prod (P3, owner decision 2026-11-05): staff + MFA Access app on the host (live/edge, same `access = "staff"`
    # model as opshub.qnsc.vn), SPA from the cluster. Everything under /api (incl. the Entra callback) and /readyz,
    # the alias of /health/ready that Synthetic Monitoring probes. Inert until edge publishes DNS for the host (its
    # cutover entry is in this PR; the data layer comes first, gitops#255). The host joins access_jwt_hosts in a
    # follow-up, once its Access app exists (the data lookup needs it).
    { hostname = "kb.qnsc.vn", path = "^/api/", service = "http://api.kb-prod.svc:8000" },
    { hostname = "kb.qnsc.vn", path = "^/readyz$", service = "http://api.kb-prod.svc:8000", bypass = true },
    { hostname = "kb.qnsc.vn", path = null, service = "http://web.kb-prod.svc:8080" },

    # rova dev — one Access app on the host (live/edge); the webhook bypass
    # lives in live/edge too, this file only routes what reaches the origin
    # The webhook rule MUST come before ^/v1/ (first match wins) and carries
    # no JWT check: a bypass Access app issues no Cf-Access-Jwt-Assertion.
    { hostname = "rova-dev.qnsc.vn", path = "^/api/auth/", service = "http://api.rova-dev.svc:3000" },
    { hostname = "rova-dev.qnsc.vn", path = "^/v1/scm/webhook/", service = "http://api.rova-dev.svc:3000", bypass = true },
    { hostname = "rova-dev.qnsc.vn", path = "^/v1/", service = "http://api.rova-dev.svc:3000" },
    { hostname = "rova-dev.qnsc.vn", path = "^/readyz$", service = "http://api.rova-dev.svc:3000", bypass = true },
    { hostname = "rova-dev.qnsc.vn", path = "^/mcp(/|$)", service = "http://api.rova-dev.svc:3000", access_app = "rova-dev MCP server" },
    # Everything else on the host is the SPA, served by the chart's web component (chart 0.19.1+, gitops#204/#218).
    # Inert while the host's Workers SPA route exists (live/edge, web = "worker"): the Worker answers first. The
    # edge PR that sets web = "cluster" removes that route; THIS rule must be applied before it.
    { hostname = "rova-dev.qnsc.vn", path = null, service = "http://web.rova-dev.svc:8080" },

    # opshub dev
    # The door terminal rule is before ^/v1/ for the same reason (bearer token
    # only, no Access session).
    { hostname = "opshub-dev.qnsc.vn", path = "^/api/auth/", service = "http://api.opshub-dev.svc:3000" },
    { hostname = "opshub-dev.qnsc.vn", path = "^/v1/door/terminal/", service = "http://api.opshub-dev.svc:3000", bypass = true },
    { hostname = "opshub-dev.qnsc.vn", path = "^/v1/", service = "http://api.opshub-dev.svc:3000" },
    { hostname = "opshub-dev.qnsc.vn", path = "^/readyz$", service = "http://api.opshub-dev.svc:3000", bypass = true },
    { hostname = "opshub-dev.qnsc.vn", path = null, service = "http://web.opshub-dev.svc:8080" },

    # kb dev — everything under /api (incl. /api/v1/auth/entra/callback) plus
    # /readyz, the alias of /health/ready that Synthetic Monitoring probes
    { hostname = "kb-dev.qnsc.vn", path = "^/api/", service = "http://api.kb-dev.svc:8000" },
    { hostname = "kb-dev.qnsc.vn", path = "^/readyz$", service = "http://api.kb-dev.svc:8000", bypass = true },
    # The SPA: the chart's in-cluster web component (kb has no Workers SPA; live/edge web = "cluster").
    { hostname = "kb-dev.qnsc.vn", path = null, service = "http://web.kb-dev.svc:8080" },
  ]
}

# ── Access JWT check at the origin (audit items 6) ──────────────────────────
#
# cloudflared validates Cf-Access-Jwt-Assertion itself (origin_request.access,
# required = true), so a request that reaches the tunnel without passing the
# host's Access app is refused even if the edge Access app is ever detached.
# Only the DEV hosts that have an Access app; rova PROD and kb-dev are not
# listed (prod has no Access by design, §8.2). Rules marked `bypass = true`
# are the Access BYPASS paths of live/edge (/readyz, the rova-dev webhook,
# the opshub-dev door terminal): those requests carry no JWT and must stay
# open, so they get no access block.
#
# The AUD tags and the team name are read from Cloudflare, not from the edge
# state: live/edge keeps its state in S3 (the AWS account closes after the
# move) and this stack's CI identity has no AWS credentials by design.
# Apps are matched by exact name = host, the name live/edge gives them. The
# lookup fails the plan if an app is missing, so a host is never left
# unchecked silently.
locals {
  # opshub.qnsc.vn: its staff Access app exists since infra#343 (same name = hostname).
  # kb.qnsc.vn: its staff Access app exists since infra#395 (edge applied 2026-11-05).
  access_jwt_hosts = toset(["rova-dev.qnsc.vn", "opshub-dev.qnsc.vn", "kb-dev.qnsc.vn", "opshub.qnsc.vn", "kb.qnsc.vn"])
  # A rule may name a different Access app than its host's (`access_app`): /mcp is behind the MCP server
  # apps (live/edge mcp.tf, mcp_rova_prod.tf), whose JWT carries THEIR aud, not the host web app's.
  access_jwt_apps = setunion(local.access_jwt_hosts, toset(compact([for r in local.qnsc_apps_ingress : try(r.access_app, "")])))
}

data "cloudflare_zero_trust_organization" "this" {
  account_id = var.cloudflare_account_id
}

data "cloudflare_zero_trust_access_application" "dev" {
  for_each = local.access_jwt_apps

  account_id = var.cloudflare_account_id
  filter = {
    name  = each.key
    exact = true
  }
}

locals {
  # team_name comes from auth_domain ("<team>.cloudflareaccess.com"), not the org display name.
  access_team_name = split(".", data.cloudflare_zero_trust_organization.this.auth_domain)[0]
}

# ── ArgoCD UI (optional admin door label `argocd`) ──────────────────────────
#
# Served by the in-cluster cloudflared (this tunnel): origin = the ArgoCD server
# Service over plain HTTP (the chart runs `server.insecure`; TLS ends at
# Cloudflare). Access (platform admins + amr=mfa, live/edge, same app shape as
# pve/pbs) is the door; cloudflared also checks its JWT. The hostname is an
# admin-door hostname (a secret in this public repo), so it only ever appears
# in sensitive attributes. Absent from ADMIN_HOSTNAMES = nothing here.
locals {
  argocd_enabled = contains(nonsensitive(keys(var.admin_hostnames)), "argocd")
}

data "cloudflare_zero_trust_access_application" "argocd" {
  count = local.argocd_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  filter = {
    name  = var.admin_hostnames["argocd"]
    exact = true
  }
}

# The pve and pbs doors (qnsc-admin tunnel). Same lookup, same reason: the rules
# below refuse a request that did not come through the host's Access app. The
# two keys are REQUIRED by the variable validation, so the lookup always exists.
data "cloudflare_zero_trust_access_application" "admin_doors" {
  for_each = toset(["pve", "pbs"])

  account_id = var.cloudflare_account_id
  filter = {
    name  = var.admin_hostnames[each.key]
    exact = true
  }
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
        hostname = r.hostname
        path     = r.path
        service  = r.service
        origin_request = {
          access = (contains(local.access_jwt_hosts, r.hostname) || try(r.access_app, "") != "") && !try(r.bypass, false) ? {
            required  = true
            team_name = local.access_team_name
            aud_tag   = [data.cloudflare_zero_trust_access_application.dev[try(r.access_app, r.hostname)].aud]
          } : null
        }
      }],
      # ArgoCD's GitHub webhook (audit M4) — BEFORE the host catch-all: first match wins, and GitHub cannot
      # present an Access session. The request authenticates with the shared webhook secret ArgoCD verifies
      # (`webhook.github.secret` in argocd-secret, ESO-synced in platform/argocd), so this rule carries no JWT
      # check, exactly like the rova-dev SCM webhook. The live/edge bypass app for the same path is the other
      # half: Access must not challenge the POST, and this file must not demand the JWT it never gets.
      [for h in data.cloudflare_zero_trust_access_application.argocd : {
        hostname       = var.admin_hostnames["argocd"]
        path           = "^/api/webhook$"
        service        = "http://argocd-server.argocd.svc:80"
        origin_request = {}
      }],
      [for h in data.cloudflare_zero_trust_access_application.argocd : {
        hostname = var.admin_hostnames["argocd"]
        path     = null
        service  = "http://argocd-server.argocd.svc:80"
        origin_request = {
          access = {
            required  = true
            team_name = local.access_team_name
            aud_tag   = [h.aud]
          }
        }
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
      # owned by live/edge (Allow grp-qnsc-platform-admins, Require amr=mfa).
      # cloudflared ALSO checks each host's Cf-Access-Jwt-Assertion here
      # (audit N-M4), exactly as the qnsc-apps rules and the argocd rule do:
      # if the Access app is detached or mis-edited at the edge, the Proxmox
      # or PBS login is not reachable from the internet. Order matters: host
      # rules BEFORE the catch-all.
      {
        hostname = var.admin_hostnames["pve"]
        path     = null
        service  = "https://localhost:8006"
        origin_request = {
          no_tls_verify = true # Proxmox pveproxy ships a self-signed cert
          access = {
            required  = true
            team_name = local.access_team_name
            aud_tag   = [data.cloudflare_zero_trust_access_application.admin_doors["pve"].aud]
          }
        }
      },
      {
        hostname = var.admin_hostnames["pbs"]
        path     = null
        service  = "https://localhost:8007"
        origin_request = {
          no_tls_verify = true # PBS ships a self-signed cert
          access = {
            required  = true
            team_name = local.access_team_name
            aud_tag   = [data.cloudflare_zero_trust_access_application.admin_doors["pbs"].aud]
          }
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
