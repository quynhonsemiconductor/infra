terraform {
  required_version = ">= 1.9"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.28" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/edge/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

# Cloudflare provider — reads the token from TF_VAR_cloudflare_api_token (or the
# CLOUDFLARE_API_TOKEN env var). Needs Zone:WAF + Zone:Rulesets edit scope on
# qnsc.vn. Leave empty to skip provider auth (e.g. plan-only bootstrapping).
provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}

# AWS provider — ACM lives in the ALB's own region (ap-southeast-1). Regional
# ALB certs (unlike CloudFront's us-east-1 requirement) must sit in-region.
provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org       = "qnsc"
      ManagedBy = "opentofu"
      Layer     = "platform"
    }
  }
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

  # Conservative per-IP rate limit on the product API surface. The free plan's
  # single included rate-limiting rule only permits a 10s counting period, a 10s
  # mitigation timeout, and simple expression operators (no `matches` regex —
  # that needs Advanced Rate Limiting). Raise/split once on Pro+.
  rate_limit_rules = [{
    ref                 = "api_default"
    description         = "Rate-limit product API endpoints per client IP"
    expression          = "(starts_with(http.request.uri.path, \"/v1/\") or starts_with(http.request.uri.path, \"/api/\"))"
    period              = 10
    requests_per_period = 300
    mitigation_timeout  = 10
  }]

  # Managed + OWASP rulesets — requires Pro+. Keep false until the zone plan is
  # confirmed; when enabling for prod, drop the AWS waf module from runtime-prod.
  enable_managed_waf = var.enable_managed_waf

  custom_firewall_rules = var.custom_firewall_rules
}

# =============================================================================
# Shared wildcard TLS certificate — *.qnsc.vn in ap-southeast-1.
#
# One regional ACM cert fronts every product API on the shared ALB
# (rally-api-dev.qnsc.vn, opshub-api-dev.qnsc.vn, …), so it lives here in the
# platform edge layer, not in any product or runtime stack. Its ARN is exported
# and consumed by runtime-dev/runtime-prod via terraform_remote_state — no human
# ever copies a cert ARN into a GitHub variable.
#
# Scope is deliberately *.qnsc.vn only (no apex SAN): the ALB serves API
# subdomains, while the apex + web hosts live on Cloudflare Pages with their own
# edge TLS. A single-label wildcard covers every *-api-<env>.qnsc.vn host.
#
# Validation is DNS-01 through the same Cloudflare zone this stack already owns
# (token: Zone:DNS:Edit). for_each is keyed on domain_name (known at plan time —
# resource_record_name is computed and would break for_each).
# =============================================================================
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.certificate_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "qnsc-wildcard-${var.certificate_domain}" }
}

resource "cloudflare_dns_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name    = trimsuffix(dvo.resource_record_name, ".")
      type    = dvo.resource_record_type
      content = trimsuffix(dvo.resource_record_value, ".")
    }
  }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  ttl     = 60
  proxied = false # validation CNAME — DNS-only, never orange-clouded
  comment = "ACM DNS validation for *.${var.certificate_domain} (qnsc-infra/edge)"
  # v5 note: v4's `allow_overwrite` is gone; the create fails loudly on a
  # conflicting record instead. This record is imported (never re-created), so
  # that path only matters on a deliberate rebuild.

  lifecycle {
    # A DNS record whose zone_id changes is destroyed and re-created, and a failed re-create is an outage (2026-10-09).
    # This stops the plan instead. To really replace it, delete this line in the same reviewed change.
    prevent_destroy = true

    precondition {
      condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
      error_message = "cloudflare_zone_id must be the 32-hex-character zone id of qnsc.vn: this resource's zone_id forces REPLACEMENT, so a null or empty value would destroy it."
    }
  }
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in cloudflare_dns_record.acm_validation : r.name]
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
  content = "v=DMARC1; p=none; rua=mailto:devops@qnsc.vn"
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

  lifecycle {
    prevent_destroy = true # destroying the Pages project deletes its deployments and detaches its custom domains: the landing site goes down
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
