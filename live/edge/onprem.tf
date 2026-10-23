# ── On-prem edge: DNS, Access, Workers routes (ONPREM-PLAN §8.2 — M-5) ──────
#
# Provider: cloudflare v4.52.9 (this stack's pin — the v5 upgrade + the Azure
# state migration for this stack are their own later PR, CUTOVER E2).
#
# ADDITIVE: nothing AWS-era is removed here. DNS records and Workers routes
# are gated on `cutover_hosts` — each host joins AT ITS CUTOVER apply (§8.2:
# "one live/edge apply per product"), with the Pages domain/records imported
# and removed in the SAME apply. rova prod resolves to AWS today and must
# keep doing so until Nov 10.
#
# ADMIN hostnames are NOT literal in this public repo — `admin_hostnames`,
# fed by a GitHub Actions repository variable. Real values: product-docs,
# runbook §12.1.

locals {
  app_hosts = {
    "rova.qnsc.vn"       = { product = "rova", env = "prod" }
    "rova-dev.qnsc.vn"   = { product = "rova", env = "dev" }
    "opshub-dev.qnsc.vn" = { product = "opshub", env = "dev" }
    "kb-dev.qnsc.vn"     = { product = "kb", env = "dev" }
  }

  # The ONLY Access bypasses (plan §8.2): /readyz per dev host + the rova-dev
  # GitHub webhook. NEVER the whole /api or /v1.
  bypass_paths = {
    for h in compact([for h, v in local.app_hosts : v.env == "dev" ? h : null]) :
    "${h}/readyz" => h
  }
  webhook_bypass = "rova-dev.qnsc.vn/v1/scm/webhook/*"

  api_paths = ["/api/*", "/v1/*", "/readyz"]
}

# ── Tunnels (created in live/onprem; data lookups gated on tunnels_exist) ───
data "cloudflare_zero_trust_tunnel_cloudflared" "qnsc_apps" {
  count      = var.tunnels_exist ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "qnsc-apps"
}

data "cloudflare_zero_trust_tunnel_cloudflared" "qnsc_admin" {
  count      = var.tunnels_exist ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "qnsc-admin"
}

# App hosts → the qnsc-apps tunnel. A host enters cutover_hosts only inside
# its move PR's apply; the Pages/legacy records for it are imported and
# removed in the SAME apply (no CNAME conflict, no early switch).
resource "cloudflare_record" "app_hosts" {
  for_each = { for h, v in local.app_hosts : h => v if var.tunnels_exist && contains(var.cutover_hosts, h) }

  zone_id = var.cloudflare_zone_id
  name    = each.key
  type    = "CNAME"
  value   = "${data.cloudflare_zero_trust_tunnel_cloudflared.qnsc_apps[0].id}.cfargotunnel.com"
  proxied = true
}

resource "cloudflare_record" "admin_hosts" {
  for_each = toset(var.tunnels_exist ? var.admin_hostnames : [])

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "CNAME"
  value   = "${data.cloudflare_zero_trust_tunnel_cloudflared.qnsc_admin[0].id}.cfargotunnel.com"
  proxied = true
}

# ── Access (v4 shape) ────────────────────────────────────────────────────────
# Entra ID is THE login method. The IdP client secret is a value and lands in
# the CF state — THE one documented exception (plan §7 records it); the state
# backend stays private + encrypted. The Entra app behind it is created
# out-of-band (owner, stdin, kv-qnsc-platform).
resource "cloudflare_zero_trust_access_identity_provider" "entra" {
  account_id = var.cloudflare_account_id
  name       = "entra"
  type       = "azureAD"

  config {
    client_id      = var.entra_idp_client_id
    client_secret  = var.entra_idp_client_secret
    directory_id   = var.entra_tenant_id
    support_groups = true # so Access can match Entra groups in policies
  }
}

# Admin doors: Allow grp-qnsc-platform-admins requiring MFA. Interim until
# FIDO2 keys exist: Entra Security Defaults + Authenticator still satisfies
# amr=mfa. Session ≤ 8 h.
resource "cloudflare_zero_trust_access_application" "admin" {
  for_each = toset(var.admin_hostnames)

  account_id       = var.cloudflare_account_id
  name             = each.value
  domain           = "${each.value}/*"
  session_duration = "8h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]
}

resource "cloudflare_zero_trust_access_policy" "admin_allow" {
  for_each = cloudflare_zero_trust_access_application.admin

  account_id       = var.cloudflare_account_id
  application_id   = each.value.id
  name             = "platform-admins-mfa"
  decision         = "allow"
  precedence       = 1
  session_duration = "8h"

  include {
    azure {
      id                   = [var.grp_platform_admins_id]
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }
  require {
    auth_method = "mfa"
  }
}

# Dev hosts: one Access app per host (§8.2), Allow grp-qnsc-developers.
resource "cloudflare_zero_trust_access_application" "dev" {
  for_each = { for h, v in local.app_hosts : h => v if v.env == "dev" }

  account_id       = var.cloudflare_account_id
  name             = each.key
  domain           = "${each.key}/*"
  session_duration = "12h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]
}

resource "cloudflare_zero_trust_access_policy" "dev_allow" {
  for_each = cloudflare_zero_trust_access_application.dev

  account_id       = var.cloudflare_account_id
  application_id   = each.value.id
  name             = "developers"
  decision         = "allow"
  precedence       = 1
  session_duration = "12h"

  include {
    azure {
      id                   = [var.grp_developers_id]
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }
}

# Bypass: <dev>/readyz (Synthetic Monitoring) and the rova-dev webhook.
resource "cloudflare_zero_trust_access_application" "dev_bypass" {
  for_each = merge(
    { for p in keys(local.bypass_paths) : p => local.bypass_paths[p] },
    { (local.webhook_bypass) = "rova-dev" },
  )

  account_id = var.cloudflare_account_id
  name       = "bypass ${each.key}"
  domain     = each.key
}

resource "cloudflare_zero_trust_access_policy" "dev_bypass" {
  for_each = cloudflare_zero_trust_access_application.dev_bypass

  account_id     = var.cloudflare_account_id
  application_id = each.value.id
  name           = "everyone-bypass"
  decision       = "bypass"
  precedence     = 1

  include {
    everyone = true
  }
}

# ── Workers routes (§8.2), gated on cutover_hosts like the DNS ──────────────
# SPA script on `<host>/*`; the API paths are no-Worker routes (script_name
# omitted — the route exists with no script, so the traffic falls through to
# the tunnel).
resource "cloudflare_workers_route" "spa" {
  for_each = { for h, v in local.app_hosts : h => v if contains(var.cutover_hosts, h) }

  zone_id     = var.cloudflare_zone_id
  pattern     = "${each.key}/*"
  script_name = "${each.value.product}-${each.value.env == "dev" ? "dev" : "prod"}-web"
}

resource "cloudflare_workers_route" "api_no_worker" {
  for_each = {
    for pair in flatten([
      for h in var.cutover_hosts : [
        for p in local.api_paths : { host = h, path = p }
      ]
    ]) : "${pair.host}${pair.path}" => pair
  }

  zone_id     = var.cloudflare_zone_id
  pattern     = "${each.value.host}${each.value.path}"
  script_name = null
}
