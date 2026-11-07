# ── MCP Server Portal `qnsc` (MCP-PLAN §5, §10 P1, §12) ─────────────────────
#
# One portal hostname in front of our MCP servers: members see one catalog and
# the CEO adds ONE claude.ai connector (the portal URL). Provider v5 expresses
# the portal and the servers (cloudflare_zero_trust_access_ai_controls_mcp_*),
# so the dashboard runbook of MCP-PLAN §12 is retired; the claude.ai connector
# stays a manual step (Claude Team Owner).
#
# Gate: the same condition as rova_dev_mcp in mcp.tf — nothing exists until
# rova-dev.qnsc.vn is cut over. The per-server Access app in mcp.tf is kept
# unchanged (the direct, pre-portal fallback path).
#
# Per-user identity: the server is registered with on_behalf = true ("Require
# user auth" ON). Never set it to false: the portal would then call rova with
# one shared credential and rova could not tell two people apart (MCP-PLAN §5).

locals {
  mcp_portal_live = contains(local.cutover_live, "rova-dev.qnsc.vn")
  mcp_portal_host = "mcp.${var.certificate_domain}"
}

# The upstream rova-dev MCP server, OAuth (per-user). Credentials are not set:
# auth_credentials is optional and the gateway registers itself with the
# upstream's Managed OAuth (DCR); no client secret is kept in code or state.
resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "rova_dev" {
  count = local.mcp_portal_live ? 1 : 0

  account_id  = var.cloudflare_account_id
  id          = "rova-dev"
  name        = "rova-dev"
  description = "rova dev MCP server (per-user OAuth)"
  hostname    = "https://rova-dev.qnsc.vn/mcp"
  auth_type   = "oauth"
  # Per-user OAuth redirects through the one Cloudflare-owned callback (allowed on the upstream app).
  is_shared_oauth_callback_enabled = true
  # Cloudflare provider 5.28.1 bug: every plan shows this server "updated in-place" from computed fields only (tools,
  # last_synced, authentication_status), and the apply then PUTs `updated_tools: null`, which the API refuses
  # (400 "Expected array, received null", infra-apply run 41639588672). Nothing here is meant to drift, so the
  # resource is frozen after create. To change hostname/auth on purpose: remove this block in the same PR (or
  # `-replace`), and put it back once the provider is fixed.
  lifecycle {
    ignore_changes = all
  }
}

# Access app that secures the server when it is reached THROUGH the portal
# (type mcp + via_mcp_server_portal destination). Same group + MFA policy as
# the direct app, so per-app authorization (MCP-PLAN §5 L1) is unchanged.
resource "cloudflare_zero_trust_access_application" "rova_dev_mcp_via_portal" {
  count = local.mcp_portal_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "rova-dev MCP server (via portal)"
  type             = "mcp"
  session_duration = "24h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  destinations = [{
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.rova_dev[0].id
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.rova_dev_mcp_allow[0].id
    precedence = 1
  }]
}

# ONE source for portal membership. Every MCP server resource in this stack is gated by its
# own live flag, so a product/env joins the portal by adding its server resource plus one line
# here — nothing else. on_behalf = true is "Require user auth" ON, never false (MCP-PLAN §5).
locals {
  mcp_portal_servers = concat(
    [for s in cloudflare_zero_trust_access_ai_controls_mcp_server.rova_dev : { server_id = s.id, on_behalf = true }],
    [for k in sort(keys(cloudflare_zero_trust_access_ai_controls_mcp_server.github)) : { server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.github[k].id, on_behalf = true }],
    [for s in cloudflare_zero_trust_access_ai_controls_mcp_server.grafana : { server_id = s.id, on_behalf = true }],
    [for s in cloudflare_zero_trust_access_ai_controls_mcp_server.rova_prod : { server_id = s.id, on_behalf = true }],
    [for s in cloudflare_zero_trust_access_ai_controls_mcp_server.opshub_dev : { server_id = s.id, on_behalf = true }],
    [for s in cloudflare_zero_trust_access_ai_controls_mcp_server.kb_dev : { server_id = s.id, on_behalf = true }],
    [for s in cloudflare_zero_trust_access_ai_controls_mcp_server.kb_prod : { server_id = s.id, on_behalf = true }],
  )

  # sort() takes strings, so sort the ids and map back: a stable triggers_replace value.
  mcp_portal_server_ids = sort([for s in local.mcp_portal_servers : s.server_id])
  mcp_portal_members    = [for id in local.mcp_portal_server_ids : { server_id = id, on_behalf = true }]
}

resource "cloudflare_zero_trust_access_ai_controls_mcp_portal" "qnsc" {
  count = local.mcp_portal_live ? 1 : 0

  account_id  = var.cloudflare_account_id
  id          = "qnsc"
  name        = "qnsc"
  hostname    = local.mcp_portal_host
  description = "QNSC MCP server portal"

  # When the provider fixes servers[] planning (see the lifecycle block below), this becomes
  # the real membership and the terraform_data below is deleted in the same PR.
  servers = local.mcp_portal_servers

  # PROVIDER BUG, still present in 5.28.1 (registry checked 2026-11-07; no 5.29): Cloudflare fills
  # servers[].updated_tools after each sync, the config never sets it, and the PUT sends
  # `updated_tools: null`, which the API refuses (400 "Expected array, received null", infra-apply run
  # 41639588672). Removing this line does NOT make a membership change apply: the next plan PUTs the
  # FULL list and either 400s or re-plans every night.
  #
  # So Terraform owns the per-server Access apps and server REGISTRATIONS, and MEMBERSHIP is set by
  # terraform_data "mcp_portal_members" below through the API (scripts/edge/mcp-portal-members.sh).
  # The script reads the portal, puts every Cloudflare-filled field (updated_tools included) back
  # unchanged, sets exactly local.mcp_portal_servers, and verifies the result. It is idempotent: an
  # apply where membership already matches sends no PUT.
  #
  # When a provider release fixes ModifyPlan for servers[], delete `servers = local.mcp_portal_servers`'s
  # guard, the terraform_data and this block in the same PR; the local is already the one source.
  lifecycle {
    ignore_changes = [servers]
  }
}

# Membership as code, around the provider bug above. triggers_replace carries the portal id and the
# sorted desired list, so the script runs when the portal is recreated or the membership changes.
# The token goes in through the environment (the apply identity's CLOUDFLARE_API_TOKEN), never argv;
# it is not stored in state. The script REFUSES a removal unless MCP_PORTAL_ALLOW_REMOVE=1: a server
# losing its live flag (count 0) or changing id must not be kicked out silently.
resource "terraform_data" "mcp_portal_members" {
  count = local.mcp_portal_live ? 1 : 0

  triggers_replace = {
    portal_id = cloudflare_zero_trust_access_ai_controls_mcp_portal.qnsc[0].id
    servers   = local.mcp_portal_members
  }

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/edge/mcp-portal-members.sh"

    environment = {
      CLOUDFLARE_API_TOKEN  = var.cloudflare_api_token
      CLOUDFLARE_ACCOUNT_ID = var.cloudflare_account_id
      MCP_PORTAL_ID         = cloudflare_zero_trust_access_ai_controls_mcp_portal.qnsc[0].id
      MCP_PORTAL_SERVERS    = jsonencode(local.mcp_portal_members)
    }
  }
}

# Portal login policy (owner decision 2026-10-24): company Entra identity,
# @qnsc.vn, amr=mfa. The IdP list is Entra only (no One-time PIN, no social).
resource "cloudflare_zero_trust_access_policy" "mcp_portal_login" {
  count = local.mcp_portal_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "mcp-portal-qnsc-login-mfa"
  decision         = "allow"
  session_duration = "24h" # grant session, spike result e (MCP-PLAN §9)

  include = [{
    email_domain = { domain = "qnsc.vn" }
  }]
  require = [{
    auth_method = { auth_method = "mfa" }
  }]
}

resource "cloudflare_zero_trust_access_application" "mcp_portal" {
  count = local.mcp_portal_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "QNSC MCP portal"
  type             = "mcp_portal"
  session_duration = "24h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  destinations = [{
    type = "public"
    uri  = local.mcp_portal_host
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.mcp_portal_login[0].id
    precedence = 1
  }]
}

# Terraform does not create the portal DNS record, and without it the portal
# answers 522. Target per the Cloudflare MCP-portal docs (API/Terraform path):
# a PROXIED CNAME to gateway.agents.cloudflare.com. The owner confirms this
# target in the dashboard portal setup before the apply (PR checklist).
resource "cloudflare_dns_record" "mcp_portal" {
  count = local.mcp_portal_live ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "mcp"
  type    = "CNAME"
  content = "gateway.agents.cloudflare.com"
  ttl     = 1
  proxied = true
  comment = "MCP server portal qnsc (qnsc-infra/edge)"
}
