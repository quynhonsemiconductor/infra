# ── On-prem edge: DNS, Access, Workers routes (ONPREM-PLAN §8.2 — M-5) ──────
#
# Provider: cloudflare v5.28 (this stack's pin, since the v5 edge migration).
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

  # door terminal (ATTENDANCE-DEVICE ADR): cannot pass Access; the app
  # verifies its bearer token, no cookie so no CSRF. Same pattern as the
  # rova SCM webhook bypass.
  door_bypass = "opshub-dev.qnsc.vn/v1/door/terminal/*"

  api_paths = ["/api/*", "/v1/*", "/readyz"]
}

# ── Tunnels (created in live/onprem; data lookups gated on tunnels_exist) ───
# v5 note: `name` moved into `filter` — it is no longer a direct lookup argument.
data "cloudflare_zero_trust_tunnel_cloudflared" "qnsc_apps" {
  count      = var.tunnels_exist ? 1 : 0
  account_id = var.cloudflare_account_id

  filter = { name = "qnsc-apps" }
}

data "cloudflare_zero_trust_tunnel_cloudflared" "qnsc_admin" {
  count      = var.tunnels_exist ? 1 : 0
  account_id = var.cloudflare_account_id

  filter = { name = "qnsc-admin" }
}

# App hosts → the qnsc-apps tunnel. A host enters cutover_hosts only inside
# its move PR's apply; the Pages/legacy records for it are imported and
# removed in the SAME apply (no CNAME conflict, no early switch).
# ttl = 1 (automatic): required in v5 and the only valid value while proxied.
# nonsensitive() only unwraps the cutover MEMBERSHIP test: its values are the
# same hostnames already public in local.app_hosts above; tofu refuses to
# touch a sensitive value in for_each.
resource "cloudflare_dns_record" "app_hosts" {
  for_each = { for h, v in local.app_hosts : h => v if var.tunnels_exist && contains(nonsensitive(var.cutover_hosts), h) }

  zone_id = var.cloudflare_zone_id
  name    = each.key
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.qnsc_apps[0].id}.cfargotunnel.com"
  ttl     = 1
  proxied = true

  lifecycle {
    # Destroying the admin door's DNS takes the operator door offline until a manual re-create.
    prevent_destroy = true # see docs/incidents/2026-10-09-edge-dns.md

    precondition {
      condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
      error_message = "cloudflare_zone_id must be the 32-hex-character zone id of qnsc.vn: this resource's zone_id forces REPLACEMENT, so a null or empty value would destroy it."
    }
  }
}

# Admin doors → the qnsc-admin tunnel. for_each runs over the LABELS of
# var.admin_hostnames (the only non-sensitive part); the hostname is a
# sensitive attribute value, so plan text shows "(sensitive value)", never
# the door hostname.
resource "cloudflare_dns_record" "admin_hosts" {
  for_each = toset(var.tunnels_exist ? nonsensitive(keys(var.admin_hostnames)) : [])

  zone_id = var.cloudflare_zone_id
  name    = var.admin_hostnames[each.value]
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.qnsc_admin[0].id}.cfargotunnel.com"
  ttl     = 1
  proxied = true

  lifecycle {
    prevent_destroy = true # see docs/incidents/2026-10-09-edge-dns.md

    precondition {
      condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
      error_message = "cloudflare_zone_id must be the 32-hex-character zone id of qnsc.vn: this resource's zone_id forces REPLACEMENT, so a null or empty value would destroy it."
    }
  }
}

# ── Access (v5 shape) ────────────────────────────────────────────────────────
# Entra ID is THE login method. The IdP client secret is a value and lands in
# the CF state — THE one documented exception (plan §7 records it); the state
# backend stays private + encrypted. The Entra app behind it is created
# out-of-band (owner, stdin, kv-qnsc-platform).
#
# v5 notes: `config` is an attribute (not a block); policies no longer take
# application_id/precedence — a policy is defined standalone and ATTACHED via
# the application's `policies` list; the IdP condition `azure` was renamed
# `azure_ad`.
resource "cloudflare_zero_trust_access_identity_provider" "entra" {
  account_id = var.cloudflare_account_id
  name       = "entra"
  type       = "azureAD"

  config = {
    client_id      = var.entra_idp_client_id
    client_secret  = var.entra_idp_client_secret
    directory_id   = var.entra_tenant_id
    support_groups = true # so Access can match Entra groups in policies
  }
}

# Admin doors: Allow grp-qnsc-platform-admins requiring MFA. Interim until
# FIDO2 keys exist: Entra Security Defaults + Authenticator still satisfies
# amr=mfa. Session ≤ 8 h. Addresses are keyed on the admin_hostnames LABELS;
# the hostnames are sensitive attribute values.
resource "cloudflare_zero_trust_access_application" "admin" {
  for_each = toset(nonsensitive(keys(var.admin_hostnames)))

  account_id       = var.cloudflare_account_id
  type             = "self_hosted" # v5: no default — required for session_duration
  name             = var.admin_hostnames[each.key]
  domain           = "${var.admin_hostnames[each.key]}/*"
  session_duration = "8h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.admin_allow[each.key].id
    precedence = 1
  }]

  lifecycle {
    # Destroying the app drops Access from the operator door: the host is exposed (or, worse, the
    # door appears missing) until a manual re-create. Replacements go through a reviewed change.
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_access_policy" "admin_allow" {
  for_each = toset(nonsensitive(keys(var.admin_hostnames)))

  account_id       = var.cloudflare_account_id
  name             = "platform-admins-mfa"
  decision         = "allow"
  session_duration = "8h"

  include = [{
    azure_ad = {
      id                   = var.grp_platform_admins_id
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }]
  require = [{
    auth_method = { auth_method = "mfa" }
  }]

  lifecycle {
    # Detaching the only allow policy on an admin door is the same exposure as deleting the app.
    prevent_destroy = true
  }
}

# Dev hosts: one Access app per host (§8.2), Allow grp-qnsc-developers —
# gated on cutover_hosts (an Access app for a host still pointing at
# AWS/Pages would be dead weight). The BYPASS apps below are harmless before
# cutover — a bypass on an unresolving host protects nothing — so they are
# not gated.
resource "cloudflare_zero_trust_access_application" "dev" {
  for_each = { for h, v in local.app_hosts : h => v if v.env == "dev" && contains(nonsensitive(var.cutover_hosts), h) }

  account_id       = var.cloudflare_account_id
  type             = "self_hosted" # v5: no default — required for session_duration
  name             = each.key
  domain           = "${each.key}/*"
  session_duration = "12h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.dev_allow[each.key].id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_policy" "dev_allow" {
  for_each = { for h, v in local.app_hosts : h => h if v.env == "dev" && contains(nonsensitive(var.cutover_hosts), h) }

  account_id       = var.cloudflare_account_id
  name             = "developers"
  decision         = "allow"
  session_duration = "12h"

  include = [{
    azure_ad = {
      id                   = var.grp_developers_id
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }]
}

# Bypass: <dev>/readyz (Synthetic Monitoring) and the rova-dev webhook.
resource "cloudflare_zero_trust_access_application" "dev_bypass" {
  for_each = merge(
    { for p in keys(local.bypass_paths) : p => local.bypass_paths[p] },
    { (local.webhook_bypass) = "rova-dev" },
    { (local.door_bypass) = "opshub-dev" },
  )

  account_id = var.cloudflare_account_id
  name       = "bypass ${each.key}"
  domain     = each.key
  # v5 sends the whole app on update; the API rejects a PUT without a type
  # (12130 "app type is missing or invalid").
  type = "self_hosted"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.dev_bypass[each.key].id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_policy" "dev_bypass" {
  for_each = merge(
    { for p in keys(local.bypass_paths) : p => local.bypass_paths[p] },
    { (local.webhook_bypass) = "rova-dev" },
    { (local.door_bypass) = "opshub-dev" },
  )

  account_id = var.cloudflare_account_id
  name       = "everyone-bypass"
  decision   = "bypass"

  include = [{ everyone = {} }]
}

# ── Workers routes (§8.2), gated on cutover_hosts like the DNS ──────────────
# SPA script on `<host>/*`; the API paths are no-Worker routes (`script`
# omitted — the route exists with no script, so the traffic falls through to
# the tunnel). v5 renamed `script_name` to `script`.
resource "cloudflare_workers_route" "spa" {
  for_each = { for h, v in local.app_hosts : h => v if contains(nonsensitive(var.cutover_hosts), h) }

  zone_id = var.cloudflare_zone_id
  pattern = "${each.key}/*"
  script  = "${each.value.product}-${each.value.env == "dev" ? "dev" : "prod"}-web"
}

resource "cloudflare_workers_route" "api_no_worker" {
  for_each = {
    for pair in flatten([
      for h in nonsensitive(var.cutover_hosts) : [
        for p in local.api_paths : { host = h, path = p }
      ]
    ]) : "${pair.host}${pair.path}" => pair
  }

  zone_id = var.cloudflare_zone_id
  pattern = "${each.value.host}${each.value.path}"
  script  = null
}
