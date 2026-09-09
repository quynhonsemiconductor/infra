terraform {
  required_version = ">= 1.9"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
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
# alongside runtime-*, not in any single product stack. The zone_id is read
# from qnsc-infra bootstrap (single source of truth). Managed WAF is OFF by
# default (Pro+ only); rate limiting is on with a conservative per-IP default.
#
# WAF ownership: if enable_managed_waf is turned on for prod, remove the AWS
# `waf` module from runtime-prod — never run both.
# =============================================================================

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

module "edge" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-edge?ref=cf-edge-v1.0.0"

  zone_id = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id

  # Conservative per-IP rate limit on the product API surface. The free plan's
  # single included rate-limiting rule only permits a 10s counting period, a 10s
  # mitigation timeout, and simple expression operators (no `matches` regex —
  # that needs Advanced Rate Limiting). Raise/split once on Pro+.
  rate_limit_rules = [{
    ref                 = "api_default"
    description         = "Rate-limit product API endpoints per client IP"
    expression          = "(starts_with(http.request.uri.path, \"/v1/\"))"
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

resource "cloudflare_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name    = dvo.resource_record_name
      type    = dvo.resource_record_type
      content = dvo.resource_record_value
    }
  }

  zone_id         = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  name            = trimsuffix(each.value.name, ".")
  type            = each.value.type
  content         = trimsuffix(each.value.content, ".")
  ttl             = 60
  proxied         = false # validation CNAME — DNS-only, never orange-clouded
  comment         = "ACM DNS validation for *.${var.certificate_domain} (qnsc-infra/edge)"
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in cloudflare_record.acm_validation : r.hostname]
}

# =============================================================================
# Shared SES domain identity — outbound mail for *.qnsc.vn products.
#
# An SES identity is per (account, region), and every product shares both — one
# AWS account, one ap-southeast-1, one qnsc.vn zone. So the identity lives here,
# in the platform edge layer, exactly like the wildcard ACM cert above: one
# resource, every product's IAM policy references it by a CONSTRUCTED ARN
# (`arn:aws:ses:<region>:<account>:identity/qnsc.vn`), never by remote-state
# lookup — so no product stack has to apply after this one to start working,
# and this stack can be applied in either order relative to a product's own.
#
# Moved here from rally/infra/live/_shared (2026-08-31): rally happened to
# create it first and opshub borrowed the same verified domain with a
# different local-part (opshub-noreply@qnsc.vn vs rally's noreply@qnsc.vn),
# which is a real dependency of opshub's on rally's infra that nothing
# declared. A domain identity fronting every product belongs at the platform
# tier, same as the zone-level WAF/rate-limiting and the wildcard cert above.
#
# NOT HANDLED HERE, AND IT CANNOT BE: the SES SANDBOX. A new account may only
# send to VERIFIED recipients until production access is granted. Check with
# `aws sesv2 get-account --query ProductionAccessEnabled`; leaving the sandbox
# is a support request, not a resource.
resource "aws_sesv2_email_identity" "mail_domain" {
  email_identity = var.mail_domain

  dkim_signing_attributes {
    # AWS-managed keys (Easy DKIM). BYODKIM would mean holding a private key in
    # state or a secret for no gain here.
    next_signing_key_length = "RSA_2048_BIT"
  }
}

/**
 * The three CNAMEs that prove the domain. Without them the identity stays `PENDING` forever and
 * every send is refused, so they belong in the same apply as the identity rather than a runbook step.
 */
resource "cloudflare_record" "ses_dkim" {
  count = 3

  zone_id = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  name    = "${aws_sesv2_email_identity.mail_domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey"
  type    = "CNAME"
  value   = "${aws_sesv2_email_identity.mail_domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"
  # Never proxied: DKIM is a DNS lookup by a receiving mail server, not HTTP traffic. Proxying it
  # would return Cloudflare's own record and the verification would never complete.
  proxied = false
  ttl     = 300

  comment = "SES DKIM for ${var.mail_domain} (managed by qnsc-infra/edge)"
}

/**
 * A custom MAIL FROM domain, so SPF ALIGNS as well as DKIM — on a SUBDOMAIN, deliberately.
 *
 * WHY NOT THE APEX. `qnsc.vn` already publishes `v=spf1 include:spf.protection.outlook.com -all` for
 * Microsoft 365, and a domain may carry only ONE SPF record: "adding SES to SPF" would mean editing
 * the record every piece of company mail depends on, ending in a hard `-all`. The benefit would be
 * zero, because DMARC passes when EITHER mechanism aligns and DKIM already signs with `d=qnsc.vn`. So
 * the apex is left alone and the envelope sender moves to `mail.qnsc.vn`, which only SES uses.
 *
 * `_dmarc.qnsc.vn` already exists and is NOT managed here: it governs M365 mail too, and tightening
 * `p=` is the domain owner's decision, not this stack's.
 *
 * `USE_DEFAULT_VALUE` on MX failure is the safe direction: if the MX below is ever missing or
 * unresolvable, SES silently falls back to `amazonses.com` and mail still goes out. `REJECT_MESSAGE`
 * would turn a DNS problem into an outage of every send.
 */
resource "aws_sesv2_email_identity_mail_from_attributes" "mail_domain" {
  email_identity         = aws_sesv2_email_identity.mail_domain.email_identity
  mail_from_domain       = "mail.${var.mail_domain}"
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

/**
 * The two records the custom MAIL FROM needs, on the subdomain only.
 *
 * The MX host is REGION-SPECIFIC (`feedback-smtp.<region>.amazonses.com`) — it is where SES asks
 * receivers to send bounces, so a wrong region silently loses them.
 */
resource "cloudflare_record" "ses_mail_from_mx" {
  zone_id  = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  name     = "mail"
  type     = "MX"
  value    = "feedback-smtp.${var.mail_region}.amazonses.com"
  priority = 10
  ttl      = 300
  comment  = "SES custom MAIL FROM (bounce path) — managed by qnsc-infra/edge"
}

resource "cloudflare_record" "ses_mail_from_spf" {
  zone_id = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  name    = "mail"
  type    = "TXT"
  # `~all`, not `-all`: multiple products send from this subdomain and a softfail cannot turn a
  # misconfiguration into silently discarded mail while a new sender's setup settles.
  value   = "v=spf1 include:amazonses.com ~all"
  ttl     = 300
  comment = "SES custom MAIL FROM SPF — managed by qnsc-infra/edge"
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
}

# Custom domains — serve the site on the apex (qnsc.vn) and www. Two parts per
# host: cloudflare_pages_domain registers the hostname with the Pages project
# (so Pages answers for it), and cloudflare_record routes traffic to the
# project's *.pages.dev origin. Proxied (orange-cloud) so Cloudflare terminates
# TLS and flattens the CNAME at the apex. Without these, qnsc.vn has no DNS and
# does not resolve — the site is only reachable at *.pages.dev.
resource "cloudflare_pages_domain" "landing" {
  for_each     = toset([var.certificate_domain, "www.${var.certificate_domain}"])
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.landing.name
  domain       = each.value
}

resource "cloudflare_record" "landing" {
  for_each = {
    (var.certificate_domain)          = var.certificate_domain # apex → CNAME-flattened
    ("www.${var.certificate_domain}") = "www"
  }

  zone_id    = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  name       = each.value
  type       = "CNAME"
  content    = cloudflare_pages_project.landing.subdomain
  ttl        = 1 # 1 = automatic (required when proxied)
  proxied    = true
  comment    = "qnsc-landing Cloudflare Pages custom domain (qnsc-infra/edge)"
  depends_on = [cloudflare_pages_domain.landing]
}

# ── Turnstile — bot challenge for the qnsc-landing contact form ───────────────
# Provisioned here (not in the landing repo) for the same reason the Pages
# project + DNS are: it is a Cloudflare account-level resource and needs the
# CF admin token, which is centralized in this stack. The public `sitekey` is an
# output (baked into the client); the `secret` is set out-of-band as the Pages
# `TURNSTILE_SECRET` env var — never injected from Terraform, matching the
# platform's secrets-out-of-band convention (see the module README).
module "landing_turnstile" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cloudflare-turnstile?ref=cloudflare-turnstile-v1.0.0"

  account_id = var.cloudflare_account_id
  name       = "qnsc-landing"
  domains    = [var.certificate_domain, "www.${var.certificate_domain}"]
  mode       = "managed"
}
