# ── KB DEV /mcp behind the portal `qnsc` (MCP-PLAN P3, kb#388/#389/#390) ────
#
# Change list: sa-notes/pending/mcp-kb-change-list-2026-11-06.md (C, 2026-11-06).
# Same shape as rova dev (mcp.tf):
#   host kb-dev.qnsc.vn, app name "kb-dev MCP server", resource label
#   kb_dev_mcp, dashboard callback .../kb-dev, output kb_dev_mcp_aud.
#
# DEV ONLY. Prod (kb.qnsc.vn/mcp) is the mcp_rova_prod.tf shape, after the release.
#
# Facts specific to KB (from C):
#   * Endpoint is /mcp (kb#388 mounts the same router there; PAT clients keep
#     using /api/v1/mcp and must NOT be pointed at /mcp — the Access app demands
#     the MCP JWT before a PAT is ever read).
#   * KB has NO Workers SPA route (web = "cluster" on both hosts), so no
#     no-Worker routes are needed; the tunnel owns every path.
#   * A /mcp tunnel rule is NEW for KB (only ^/api/ and ^/readyz$ were routed):
#     live/onprem/tunnels.tf gets the rule with access_app = this app's name.
#   * Managed OAuth discovery is answered by Access at the edge; the app only
#     verifies the forwarded JWT, so no app-side discovery work.
#
# Per-user identity: on_behalf = true through the portal; L2 stays KB's RBAC +
# set_database_context. The JWT the API verifies carries THIS app's aud.

locals {
  kb_dev_mcp_live = contains(local.cutover_live, "kb-dev.qnsc.vn")

  # COUPLED ON PURPOSE to local.mcp_portal_live (mcp_portal.tf), which is the
  # rova-dev cutover flag: the portal is ONE resource owned by that gate, so a
  # server registration without a portal cannot exist. If rova-dev ever leaves
  # `cutover`, the portal (and this registration) would be destroyed — a
  # portal-wide decision, reviewed in mcp_portal.tf, not a silent side effect of
  # this file. A separate "portal exists" variable would only hide that.
  kb_dev_in_portal = local.kb_dev_mcp_live && local.mcp_portal_live
}

resource "cloudflare_zero_trust_access_application" "kb_dev_mcp" {
  count = local.kb_dev_mcp_live ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "kb-dev MCP server"
  domain     = "kb-dev.qnsc.vn/mcp"
  type       = "self_hosted"

  # The discovery path must belong to this app, or the in-cluster web component
  # answers it with HTML (kb-dev has no Workers SPA).
  destinations = [
    { type = "public", uri = "kb-dev.qnsc.vn/mcp" },
    { type = "public", uri = "kb-dev.qnsc.vn/.well-known/oauth-authorization-server" },
  ]
  session_duration = "24h" # the OAuth GRANT session (MCP-PLAN §5)
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  oauth_configuration = {
    enabled = true
    dynamic_client_registration = {
      enabled                = true
      allow_any_on_localhost = true
      allow_any_on_loopback  = true
      allowed_uris = [
        "https://claude.ai/api/mcp/auth_callback",
        "https://dash.cloudflare.com/${var.cloudflare_account_id}/one/access-controls/ai-controls/mcp-server/oauth-callback/kb-dev",
        "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
      ]
    }
    grant = {
      access_token_lifetime = "15m"
    }
  }

  policies = [{
    id         = cloudflare_zero_trust_access_policy.kb_dev_mcp_allow[0].id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_policy" "kb_dev_mcp_allow" {
  count = local.kb_dev_mcp_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "kb-dev-mcp-mfa"
  decision         = "allow"
  session_duration = "24h"

  # grp-qnsc-developers + grp-qnsc-dev-users, same dev pair as the kb-dev host
  # app and the rova-dev MCP policy. Include = OR.
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

resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "kb_dev" {
  count = local.kb_dev_in_portal ? 1 : 0

  account_id  = var.cloudflare_account_id
  id          = "kb-dev"
  name        = "kb-dev"
  description = "KB dev MCP server (per-user OAuth)"
  hostname    = "https://kb-dev.qnsc.vn/mcp"
  auth_type   = "oauth"

  is_shared_oauth_callback_enabled = true

  lifecycle {
    ignore_changes = all # provider 5.28.1 updated_tools bug, same as rova_dev
  }
}

resource "cloudflare_zero_trust_access_application" "kb_dev_mcp_via_portal" {
  count = local.kb_dev_in_portal ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "kb-dev MCP server (via portal)"
  type             = "mcp"
  session_duration = "24h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  destinations = [{
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.kb_dev[0].id
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.kb_dev_mcp_allow[0].id
    precedence = 1
  }]
}

output "kb_dev_mcp_aud" {
  description = "AUD tag of the kb-dev /mcp Access app — the value the KB API pins as MCP_ACCESS_AUD (kv-qnsc-dev/kb-dev-mcp-access-aud)."
  value       = one(cloudflare_zero_trust_access_application.kb_dev_mcp[*].aud)
}

# No cloudflare_workers_route: kb-dev has web = "cluster" (no SPA Worker). The
# /mcp tunnel rule is in live/onprem/tunnels.tf and must precede the host
# catch-all there.
