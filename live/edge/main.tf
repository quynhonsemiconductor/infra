terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.28" }
  }

  # State lives on Azure (AWS exit, 2026-11-02): same account and auth as
  # live/identity and live/onprem. use_azuread_auth stays ON (shared keys are
  # disabled on the account; the CI identities have data-plane roles only).
  backend "azurerm" {
    use_azuread_auth     = true
    resource_group_name  = "rg-qnsc-platform"
    storage_account_name = "stqnsctfstate"
    container_name       = "tfstate"
    key                  = "infra/edge/terraform.tfstate"
  }
}

# Cloudflare provider — reads the token from TF_VAR_cloudflare_api_token (or the
# CLOUDFLARE_API_TOKEN env var). Needs Zone:WAF + Zone:Rulesets edit scope on
# qnsc.vn. Leave empty to skip provider auth (e.g. plan-only bootstrapping).
provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}

# =============================================================================
# Shared edge governance — Cloudflare WAF + rate-limiting for the qnsc.vn zone.
#
# Zone-level (one zone fronts every product), so it lives in the platform layer
# alongside runtime-*, not in any single product stack. The zone_id is a VALIDATED VARIABLE
# (var.cloudflare_zone_id; CI: vars.CLOUDFLARE_ZONE_ID). It used to be read from bootstrap's
# remote state, where one apply that missed TF_VAR_cloudflare_zone_id exported "" and the next
# edge apply destroyed every DNS record (docs/incidents/2026-10-09-edge-dns.md). Managed WAF is OFF by
# default (Pro+ only); rate limiting is on with a conservative per-IP default.
#
# WAF ownership: if enable_managed_waf is turned on for prod, remove the AWS
# `waf` module from runtime-prod — never run both.
# =============================================================================

module "edge" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-edge?ref=cf-edge-v2.0.0"

  zone_id = var.cloudflare_zone_id

  # Per-IP limit on the AUTH paths only (audit N-M7), in LOG mode for the
  # first 7 days (review 2026-11-04): the office has one NAT address, so a
  # block threshold that is right per-client is wrong per-office. Log mode
  # counts and emits Security Events without dropping a sign-in; after a week
  # of real numbers, switch action to "block" with a threshold chosen from them.
  #
  # The free plan allows one rate rule with a 10s counting period, a 10s
  # mitigation timeout and simple expression operators (no `matches` regex —
  # that needs Advanced Rate Limiting), so the one rule covers the explicit
  # auth surface of all three products:
  #   rova, opshub   /api/auth/*        (tunnel rules: ^/api/auth/)
  #   kb             /api/v1/auth/*     (incl. /api/v1/auth/entra/callback)
  #
  # Everything else is deliberately NOT rate-limited at the edge any more. The
  # old rule (300 req/10s per IP across all /v1/ and /api/) is REMOVED: it was
  # too loose to stop credential stuffing, wide enough to throttle a busy
  # dashboard, and it keyed on the office NAT rather than on an identity. The
  # apps limit the API themselves, in Valkey:
  #   rova     libs/platform/src/rate-limit/rate-limit.constants.ts
  #            PRE_AUTH 1200/60s per IP, DEFAULT 100/60s per user; the
  #            /api/auth/* routes are further limited in identity (redirects
  #            120/60s, callbacks 100/10s)
  #   opshub   libs/platform/src/rate-limit/rate-limit.constants.ts
  #            PRE_AUTH_IP_BUCKET 1000/60s per IP, DEFAULT 200/60s per user,
  #            STRICT 60/60s, AI 10/60s, UPLOAD 30/60s
  rate_limit_rules = [{
    ref = "auth_default"
    # Only the PUBLIC sign-in of rova prod: every other host is behind Cloudflare Access (an unauthenticated
    # client never reaches its /api/auth), and the apps rate-limit per IP and per user themselves (Valkey).
    # Only the real sign-in endpoints — never get-session — so normal staff traffic (whole office behind one
    # NAT IP) cannot trip it, while a credential-stuffing burst does. `log` is not on the zone plan.
    description         = "Block an IP that sends more than 100 rova prod sign-in requests in 10 seconds"
    expression          = "(http.host eq \"rova.qnsc.vn\" and (starts_with(http.request.uri.path, \"/api/auth/sign-in\") or starts_with(http.request.uri.path, \"/api/auth/callback\")))"
    period              = 10
    requests_per_period = 100
    mitigation_timeout  = 10
    action              = "block"
  }]

  # Managed + OWASP rulesets — requires Pro+. Keep false until the zone plan is
  # confirmed; when enabling for prod, drop the AWS waf module from runtime-prod.
  # Owner decision 2026-11-01: the FREE managed ruleset, not the Pro pair. The
  # module's default list is the Pro Managed + OWASP rulesets, which the zone's
  # plan refuses ("not entitled"), so the list is explicit here.
  enable_managed_waf  = var.enable_managed_waf
  managed_ruleset_ids = ["77454fe2d30c4220b5701f6fdfb893ba"] # Cloudflare Free Managed Ruleset

  custom_firewall_rules = var.custom_firewall_rules
}

# ── Response hardening for the asset host ───────────────────────────────────
# rova-assets.qnsc.vn serves user-uploaded objects from R2 through Cloudflare.
# Browsers must not guess a type for them, whatever R2 returns.
resource "cloudflare_ruleset" "assets_nosniff" {
  zone_id     = var.cloudflare_zone_id
  name        = "qnsc asset response headers"
  description = "X-Content-Type-Options: nosniff on the asset host."
  kind        = "zone"
  phase       = "http_response_headers_transform"

  rules = [{
    ref         = "assets_nosniff"
    description = "nosniff on rova-assets.qnsc.vn"
    expression  = "http.host eq \"rova-assets.qnsc.vn\""
    action      = "rewrite"
    enabled     = true

    action_parameters = {
      headers = {
        "X-Content-Type-Options" = { operation = "set", value = "nosniff" }
      }
    }
  }]
}

# =============================================================================
# AWS exit (2026-11-02): the AWS side of this stack is gone. The ACM wildcard
# certificate, the SES identity and its MAIL FROM attributes were forgotten in
# state by `tofu state rm` before the state moved to Azure (they die with the
# AWS account). The Cloudflare DNS records that served them are forgotten here:
# `removed {}` in OpenTofu 1.9.1 only drops the object from state and never
# destroys it (there is no `destroy` argument). The records stay in the zone
# until deleted by hand in the dashboard (audit E-5): the three SES DKIM CNAMEs,
# the `mail` MX and SPF TXT. Nothing sends through SES any more.
# =============================================================================
removed {
  from = cloudflare_dns_record.ses_dkim
}

removed {
  from = cloudflare_dns_record.ses_mail_from_mx
}

removed {
  from = cloudflare_dns_record.ses_mail_from_spf
}

# DMARC for qnsc.vn. It was set by hand in the Cloudflare dashboard (2026-10-13) and is IMPORTED here, not re-created: the import
# block adopted the existing record, so that apply changed nothing about DNS. (The import block was applied on 2026-10-13 and removed.)
#
# p=none is deliberate for now: it only COLLECTS reports (rua) and rejects or quarantines nothing, so a sender we forgot about (Microsoft 365
# for the staff mailboxes, SES for the products) cannot have its mail dropped while the reports are still unread.
#
# PLAN: read the aggregate reports for 2-4 weeks. When every legitimate source (Microsoft 365 via spf.protection.outlook.com, SES via
# amazonses.com, with DKIM aligned) passes and only noise fails, move to p=quarantine, then to p=reject after another clean period.
# Each step is its own PR so the change and the reports that justified it are reviewable together.
resource "cloudflare_dns_record" "dmarc" {
  zone_id = var.cloudflare_zone_id
  name    = "_dmarc"
  type    = "TXT"
  # Exactly what is live (read from the CI plan of the import): TTL 1 = Cloudflare "automatic", no comment, content as typed. Matching it
  # is what makes the first apply a pure IMPORT. Quote the content and set a comment in a follow-up in-place update (as for the SPF record),
  # not in the same change as the import.
  # 2026-11-05: p=none -> p=quarantine. Aggregate reports 2026-10-27..11-04 (Microsoft + Google, ~25 messages):
  # every legitimate message came from Microsoft 365 (2a01:111:f403::/48) and passed DMARC through aligned SPF;
  # the only failure was one message forwarded through a third-party Google Workspace (SPF aligned to the
  # forwarder, no DKIM yet). Microsoft 365 DKIM for qnsc.vn is Valid since 2026-11-05, so forwarded mail now
  # carries an aligned signature too. Products send through Graph (Microsoft 365), not SES. Next step, p=reject,
  # after ~2 clean weeks of reports showing DKIM pass.
  content = "v=DMARC1; p=quarantine; rua=mailto:devops@qnsc.vn"
  ttl     = 1

  lifecycle {
    prevent_destroy = true # see docs/incidents/2026-10-09-edge-dns.md

    precondition {
      condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
      error_message = "cloudflare_zone_id must be the 32-hex-character zone id of qnsc.vn: this resource's zone_id forces REPLACEMENT, so a null or empty value would destroy it."
    }
  }
}

# =============================================================================
# Cloudflare Pages — static sites (qnsc-landing, …).
#
# The Pages *project* is infrastructure, so it is declared here in code rather
# than clicked into existence. This makes it reproducible across account
# migrations (a fresh Cloudflare account is one `tofu apply` away) and removes
# any manual dashboard step — the exact failure that broke the qnsc-landing
# deploy after the account move. The web-deploy CI only uploads built assets to
# the already-provisioned project via `wrangler pages deploy` — pure CD, no
# provisioning.
#
# Direct-upload project (no `source` block → not Git-connected). The production
# branch is `main` to match the deploy command's `--branch=main`.
# =============================================================================
resource "cloudflare_pages_project" "landing" {
  account_id        = var.cloudflare_account_id
  name              = "qnsc-landing"
  production_branch = "main"

  # Codified, not ignored: the provider has no state-preserving plan modifier on build_config /
  # build_image_auto_upgrade (cloudflare/terraform-provider-cloudflare#7288, #7262), so on a direct-upload
  # project — where the API's build_config is empty — every plan re-marked the omitted members
  # "(known after apply)" and edge never converged. `ignore_changes` cannot help: it retains the value
  # *originally configured*, and build_image_auto_upgrade is provider-computed (OpenTofu warns, no effect).
  # Naming every member keeps the whole object known; empty strings are what the API returns for a
  # direct-upload project, so the values are the real config, not a suppression.
  build_config = {
    build_caching       = false
    build_command       = ""
    destination_dir     = ""
    root_dir            = ""
    web_analytics_tag   = ""
    web_analytics_token = ""
  }

  lifecycle {
    prevent_destroy = true # destroying the Pages project deletes its deployments and detaches its custom domains: the landing site goes down
    # build_image_auto_upgrade is provider-computed (it records Cloudflare's v1→v3 build-image move): it cannot be
    # named here and needs no entry — with the update above applied once, no other change is planned and it stays
    # known. Re-check this when the provider gains UseStateForUnknown on these attributes.
  }
}

# Custom domains — serve the site on the apex (qnsc.vn) and www. Two parts per
# host: cloudflare_pages_domain registers the hostname with the Pages project
# (so Pages answers for it), and cloudflare_dns_record routes traffic to the
# project's *.pages.dev origin. Proxied (orange-cloud) so Cloudflare terminates
# TLS and flattens the CNAME at the apex. Without these, qnsc.vn has no DNS and
# does not resolve — the site is only reachable at *.pages.dev.
resource "cloudflare_pages_domain" "landing" {
  for_each     = toset([var.certificate_domain, "www.${var.certificate_domain}"])
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.landing.name
  name         = each.value # v5: was `domain`

  lifecycle {
    prevent_destroy = true # destroying the Pages domain detaches the hostname from the project: the site stops answering on it
  }
}

resource "cloudflare_dns_record" "landing" {
  for_each = {
    (var.certificate_domain)          = var.certificate_domain # apex → CNAME-flattened
    ("www.${var.certificate_domain}") = "www"
  }

  zone_id    = var.cloudflare_zone_id
  name       = each.value
  type       = "CNAME"
  content    = cloudflare_pages_project.landing.subdomain
  ttl        = 1 # 1 = automatic (required when proxied)
  proxied    = true
  comment    = "qnsc-landing Cloudflare Pages custom domain (qnsc-infra/edge)"
  depends_on = [cloudflare_pages_domain.landing]

  lifecycle {
    prevent_destroy = true # see docs/incidents/2026-10-09-edge-dns.md

    precondition {
      condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
      error_message = "cloudflare_zone_id must be the 32-hex-character zone id of qnsc.vn: this resource's zone_id forces REPLACEMENT, so a null or empty value would destroy it."
    }
  }
}

# ── Turnstile — bot challenge for the qnsc-landing contact form ───────────────
# Provisioned here (not in the landing repo) for the same reason the Pages
# project + DNS are: it is a Cloudflare account-level resource and needs the
# CF admin token, which is centralized in this stack. The public `sitekey` is an
# output (baked into the client); the `secret` is set out-of-band as the Pages
# `TURNSTILE_SECRET` env var — never injected from Terraform, matching the
# platform's secrets-out-of-band convention (see the module README).
module "landing_turnstile" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cloudflare-turnstile?ref=cloudflare-turnstile-v2.0.0"

  account_id = var.cloudflare_account_id
  name       = "qnsc-landing"
  domains    = [var.certificate_domain, "www.${var.certificate_domain}"]
  mode       = "managed"
}
