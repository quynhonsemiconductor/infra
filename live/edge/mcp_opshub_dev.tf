# ── opshub DEV /mcp behind the portal `qnsc` (MCP-PLAN P3, opshub#559/#560) ──
#
# Change list: product-docs/platform/mcp/OPSHUB-MCP-EDGE.md (§1, §2), 2026-11-06.
# Shape copied from rova dev (mcp.tf) with the substitutions the list names:
#   host opshub-dev.qnsc.vn, app name "opshub-dev MCP server", resource label
#   opshub_dev_mcp, dashboard callback .../opshub-dev, output opshub_dev_mcp_aud.
#
# DEV ONLY. Prod (opshub.qnsc.vn/mcp) is the mcp_rova_prod.tf shape and waits for
# the opshub release.
#
# Gate: contains(local.cutover_live, "opshub-dev.qnsc.vn") — live since 2026-11-01.
#
# Per-user identity: the portal registers this server with on_behalf = true
# ("Require user auth" ON). NEVER false: a shared credential would make every
# caller the same identity, the god account MCP-PLAN §5 forbids. L2 stays
# opshub's own PolicyGuard; the JWT the API verifies carries THIS app's aud.
#
# The API side is inert until MCP_ENABLED=true + MCP_ACCESS_AUD (gitops, after
# this apply): the route answers 404/503, never an open door.

locals {
  opshub_dev_mcp_live = contains(local.cutover_live, "opshub-dev.qnsc.vn")

  # COUPLED ON PURPOSE to local.mcp_portal_live (mcp_portal.tf), which is the
  # rova-dev cutover flag: the portal is ONE resource owned by that gate, so a
  # server registration without a portal cannot exist. If rova-dev ever leaves
  # `cutover`, the portal (and this registration) would be destroyed — a
  # portal-wide decision, reviewed in mcp_portal.tf, not a silent side effect of
  # this file. A separate "portal exists" variable would only hide that.
  opshub_dev_in_portal = local.opshub_dev_mcp_live && local.mcp_portal_live
}

resource "cloudflare_zero_trust_access_application" "opshub_dev_mcp" {
  count = local.opshub_dev_mcp_live ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "opshub-dev MCP server"
  domain     = "opshub-dev.qnsc.vn/mcp"
  type       = "self_hosted"

  # Access serves the OAuth metadata at <host>/.well-known/oauth-authorization-server.
  # That path must belong to THIS app: there is no SPA Worker on opshub-dev (web =
  # "cluster"), but the in-cluster web component would answer it with HTML and an
  # MCP client could not discover the authorization server.
  destinations = [
    { type = "public", uri = "opshub-dev.qnsc.vn/mcp" },
    { type = "public", uri = "opshub-dev.qnsc.vn/.well-known/oauth-authorization-server" },
  ]
  session_duration = "24h" # the OAuth GRANT session (MCP-PLAN §5: chosen 24 h)
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  # Managed OAuth: Access is the OAuth server for this app. Redirect URIs a
  # dynamically registered client may use: claude.ai, the portal's admin
  # authorization (dashboard callback, per account and server) and the shared
  # Cloudflare callback the portal uses per user. Localhost/loopback for Claude Code.
  oauth_configuration = {
    enabled = true
    dynamic_client_registration = {
      enabled                = true
      allow_any_on_localhost = true
      allow_any_on_loopback  = true
      allowed_uris = [
        "https://claude.ai/api/mcp/auth_callback",
        "https://dash.cloudflare.com/${var.cloudflare_account_id}/one/access-controls/ai-controls/mcp-server/oauth-callback/opshub-dev",
        "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
      ]
    }
    grant = {
      access_token_lifetime = "15m"
    }
  }

  policies = [{
    id         = cloudflare_zero_trust_access_policy.opshub_dev_mcp_allow[0].id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_policy" "opshub_dev_mcp_allow" {
  count = local.opshub_dev_mcp_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "opshub-dev-mcp-mfa"
  decision         = "allow"
  session_duration = "24h"

  # grp-qnsc-developers + grp-qnsc-dev-users, the same dev pair as the
  # opshub-dev host app and the rova-dev MCP policy. Include = OR.
  include = [for g in compact([var.grp_developers_id, var.grp_dev_users_id]) : {
    azure_ad = {
      id                   = g
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }]
  require = [{
    auth_method = { auth_method = "mfa" }
  }]
}

# Upstream registration in the portal `qnsc`. Frozen after create for the same
# provider 5.28.1 reason as rova_dev (updated_tools: null on every PUT): change
# auth/hostname on purpose by removing this block in that PR.
resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "opshub_dev" {
  count = local.opshub_dev_in_portal ? 1 : 0

  account_id  = var.cloudflare_account_id
  id          = "opshub-dev"
  name        = "opshub-dev"
  description = "opshub dev MCP server (per-user OAuth)"
  hostname    = "https://opshub-dev.qnsc.vn/mcp"
  auth_type   = "oauth"

  is_shared_oauth_callback_enabled = true

  lifecycle {
    ignore_changes = all
  }
}

# L1 for the path THROUGH the portal: same policy as the direct app.
resource "cloudflare_zero_trust_access_application" "opshub_dev_mcp_via_portal" {
  count = local.opshub_dev_in_portal ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "opshub-dev MCP server (via portal)"
  type             = "mcp"
  session_duration = "24h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  destinations = [{
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.opshub_dev[0].id
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.opshub_dev_mcp_allow[0].id
    precedence = 1
  }]
}

output "opshub_dev_mcp_aud" {
  description = "AUD tag of the opshub-dev /mcp Access app — the value the opshub API pins as MCP_ACCESS_AUD (kv-qnsc-dev/opshub-dev-mcp-access-aud)."
  value       = one(cloudflare_zero_trust_access_application.opshub_dev_mcp[*].aud)
}

# No cloudflare_workers_route here on purpose: opshub-dev has web = "cluster" (no
# SPA Worker), so /mcp falls straight through the tunnel. If a Workers SPA route
# is ever added for opshub-dev.qnsc.vn/*, add the /mcp and /mcp/* no-Worker routes
# exactly as mcp.tf does for rova-dev.
