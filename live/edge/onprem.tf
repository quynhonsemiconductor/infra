# ── On-prem edge: DNS, Access, Workers routes (ONPREM-PLAN §8.2 — M-5) ──────
#
# ADDITIVE: nothing AWS-era is removed here. The ACM/SES/Pages resources stay
# until each product's cutover apply (§8.2 "one live/edge apply per product")
# and Stage E — this file only ADDS the on-prem doors so the day-of work is
# apply-only.
#
# One host per app (§8.2): a Worker serves the SPA on `<app>[-dev].qnsc.vn/*`;
# the API paths are no-Worker routes (they negate the SPA route and fall
# through to the qnsc-apps tunnel, whose ingress lives in live/onprem).
#
# ADMIN hostnames are NOT literal in this public repo — they come from the
# `admin_hostnames` variable, fed by a GitHub Actions repository variable
# (`TF_VAR_admin_hostnames` on the infra `prod` environment). The real values
# are recorded in product-docs (runbook §12.1: pve/pbs.qnsc.vn).

locals {
  # host → product/env. Product hostnames are already public elsewhere in this
  # repo (live/onprem/tunnels.tf); only admin hostnames are variable-fed.
  app_hosts = {
    "rova.qnsc.vn"       = { product = "rova", env = "prod" }
    "rova-dev.qnsc.vn"   = { product = "rova", env = "dev" }
    "opshub-dev.qnsc.vn" = { product = "opshub", env = "dev" }
    "kb-dev.qnsc.vn"     = { product = "kb", env = "dev" }
  }

  # API paths that must NOT hit the SPA Worker (§8.2 table). The MCP paths
  # (/.well-known/oauth-*, /mcp) join when AI-4 ships.
  api_paths = ["/api/*", "/v1/*", "/readyz"]
}

# ── The qnsc-apps tunnel (created in live/onprem) — data only ───────────────
data "cloudflare_zero_trust_tunnel_cloudflared" "qnsc_apps" {
  account_id = var.cloudflare_account_id
  name       = "qnsc-apps"
}

# Every app host → the tunnel. Proxied, no origin: the tunnel IS the origin.
resource "cloudflare_record" "app_hosts" {
  for_each = local.app_hosts

  zone_id = var.cloudflare_zone_id
  name    = each.key
  type    = "CNAME"
  value   = "${data.cloudflare_zero_trust_tunnel_cloudflared.qnsc_apps.id}.cfargotunnel.com"
  proxied = true
}

# Admin hostnames → the qnsc-admin tunnel (door 2). Values from CI variables.
data "cloudflare_zero_trust_tunnel_cloudflared" "qnsc_admin" {
  account_id = var.cloudflare_account_id
  name       = "qnsc-admin"
}

resource "cloudflare_record" "admin_hosts" {
  for_each = toset(var.admin_hostnames)

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "CNAME"
  value   = "${data.cloudflare_zero_trust_tunnel_cloudflared.qnsc_admin.id}.cfargotunnel.com"
  proxied = true
}

# ── Access (v5 shape: policies attach to their application via application_id)
# Entra ID is THE login method. The IdP client secret is a value — fed as a
# sensitive CI variable; the Entra app behind it is created out-of-band (owner,
# stdin, kv-qnsc-platform).
resource "cloudflare_zero_trust_access_identity_provider" "entra" {
  account_id = var.cloudflare_account_id
  name       = "entra"
  type       = "azureAD"
  config {
    client_id     = var.entra_idp_client_id
    client_secret = var.entra_idp_client_secret
    directory_id  = var.entra_tenant_id
  }
}

# Admin doors: Allow grp-qnsc-platform-admins requiring MFA. Interim until
# FIDO2 keys exist: Entra Security Defaults + Authenticator still satisfy
# amr=mfa. No bypass.
resource "cloudflare_zero_trust_access_application" "admin" {
  for_each = toset(var.admin_hostnames)

  account_id       = var.cloudflare_account_id
  zone_id          = var.cloudflare_zone_id
  name             = each.value
  domain           = "${each.value}/*"
  session_duration = "12h"
}

resource "cloudflare_zero_trust_access_policy" "admin_allow" {
  for_each = cloudflare_zero_trust_access_application.admin

  account_id       = var.cloudflare_account_id
  zone_id          = var.cloudflare_zone_id
  application_id   = each.value.id
  name             = "platform-admins-mfa"
  decision         = "allow"
  precedence       = 1
  session_duration = "12h"

  include {
    group = [var.grp_platform_admins_id]
  }
  require {
    auth_method = "mfa"
  }
}

# Dev hosts: one Access app per host (§8.2), Allow grp-qnsc-developers.
resource "cloudflare_zero_trust_access_application" "dev" {
  for_each = { for h, v in local.app_hosts : h => v if v.env == "dev" }

  account_id       = var.cloudflare_account_id
  zone_id          = var.cloudflare_zone_id
  name             = each.key
  domain           = "${each.key}/*"
  session_duration = "12h"
}

resource "cloudflare_zero_trust_access_policy" "dev_allow" {
  for_each = cloudflare_zero_trust_access_application.dev

  account_id       = var.cloudflare_account_id
  zone_id          = var.cloudflare_zone_id
  application_id   = each.value.id
  name             = "developers"
  decision         = "allow"
  precedence       = 1
  session_duration = "12h"

  include {
    group = [var.grp_developers_id]
  }
}

# Bypass: /readyz on every dev host (Synthetic Monitoring) and the rova-dev
# GitHub webhook (GitHub cannot pass Access; the app verifies the signature).
resource "cloudflare_zero_trust_access_application" "dev_bypass" {
  for_each = toset(flatten([
    for h in [for h, v in local.app_hosts : v.env == "dev" ? h : null] : [
      for p in local.api_paths : "${h}${replace(p, "/*", "")}"
    ]
  ]))

  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  name       = "bypass ${each.value}"
  domain     = each.value
}

resource "cloudflare_zero_trust_access_policy" "dev_bypass" {
  for_each = cloudflare_zero_trust_access_application.dev_bypass

  account_id     = var.cloudflare_account_id
  zone_id        = var.cloudflare_zone_id
  application_id = each.value.id
  name           = "everyone-bypass"
  decision       = "bypass"
  precedence     = 1

  include {
    everyone = true
  }
}

# ── Workers routes (§8.2): SPA on /*, API paths run NO worker ───────────────
# The Worker scripts themselves are deployed by the product repos (cf-ci-web);
# these routes only bind the zone. script = "" on the API paths is the
# no-Worker route — VERIFY at plan time that the v5 attribute is script_name; an empty
# script_name creates the no-Worker route. VERIFY at plan time that the API
# accepts it — if it rejects an empty name, the alternative (a dedicated
# pass-through Worker) gets recorded here.
resource "cloudflare_workers_route" "spa" {
  for_each = local.app_hosts

  zone_id     = var.cloudflare_zone_id
  pattern     = "${each.key}/*"
  script_name = "${each.value.product}-${each.value.env == "dev" ? "dev" : "prod"}-web"
}

resource "cloudflare_workers_route" "api_no_worker" {
  for_each = {
    for pair in flatten([
      for h, v in local.app_hosts : [
        for p in local.api_paths : { host = h, path = p }
      ]
    ]) : "${pair.host}${pair.path}" => pair
  }

  zone_id     = var.cloudflare_zone_id
  pattern     = "${each.value.host}${each.value.path}"
  script_name = ""
}
