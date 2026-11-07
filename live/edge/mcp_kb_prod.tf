# ── KB PROD /mcp behind the MCP portal `qnsc` (MCP-PLAN P3) ──────────────────
#
# Same shape as rova prod (mcp_rova_prod.tf), for https://kb.qnsc.vn/mcp:
#   1. a path-scoped Access app on kb.qnsc.vn/mcp (direct fallback path), group + MFA policy;
#   2. the upstream registered in portal `qnsc` as `kb-prod`, "Require user auth" ON
#      (on_behalf = true, never false: KB must see one identity per person);
#   3. portal membership: mcp_portal.tf's terraform_data "mcp_portal_members" adds this server
#      from local.mcp_portal_servers — not a dashboard step.
#
# KB has NO Workers SPA route (web = "cluster" on both hosts, onprem.tf), so unlike rova
# there are no no-Worker routes to negate; the tunnel owns every path. The /mcp ingress rule
# is in live/onprem/tunnels.tf.
#
# POLICY GROUPS: same as rova prod — grp-qnsc-staff (every employee; owner decision
# 2026-11-03) plus grp-qnsc-developers and grp-qnsc-dev-users, kept so nobody loses access
# before staff is populated. KB's RBAC + set_database_context still decides every result,
# and an Access caller is read-only by construction (AccessPrincipal.can_write is False;
# no write flag exists on the KB side).
#
# MERGE/APPLY ORDER (the audience is an edge output): live/edge apply creates the app and
# prints `kb_prod_mcp_aud` → the owner copies it into kv-qnsc-prod/kb-prod-mcp-access-aud →
# the gitops values change (MCP_ENABLED + MCP_CF_TEAM_DOMAIN + MCP_ACCESS_AUD) merges →
# the live/onprem tunnel rule applies. The ExternalSecret fails entirely if the AUD secret
# is referenced before it exists, which is why gitops does not land before the edge apply.
#
# OWNER CLICK-STEP: authenticate the server once in the MCP portal (see mcp.tf); Managed
# OAuth and portal membership are IaC. IdP = Entra only.

locals {
  kb_prod_mcp_live = contains(local.cutover_live, "kb.qnsc.vn")

  # COUPLED ON PURPOSE to local.mcp_portal_live (mcp_portal.tf): the portal is ONE
  # resource, so a server registration without a portal cannot exist.
  kb_prod_in_portal = local.kb_prod_mcp_live && local.mcp_portal_live
}

resource "cloudflare_zero_trust_access_policy" "kb_prod_mcp_allow" {
  count = local.kb_prod_mcp_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "kb-prod-mcp-mfa"
  decision         = "allow"
  session_duration = "24h"

  # grp-qnsc-staff (everyone) + developers + dev-users: identical to rova prod. Include = OR.
  include = [for g in compact([var.grp_developers_id, var.grp_dev_users_id, var.grp_staff_id]) : {
    azure_ad = {
      id                   = g
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }]
  require = [{
    auth_method = { auth_method = "mfa" }
  }]
}

resource "cloudflare_zero_trust_access_application" "kb_prod_mcp" {
  count = local.kb_prod_mcp_live ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "kb-prod MCP server"
  domain     = "kb.qnsc.vn/mcp"
  type       = "self_hosted"

  # Access serves the OAuth metadata at <host>/.well-known/oauth-authorization-server
  # (Managed OAuth). That path must belong to this app, or the in-cluster web component
  # answers it with HTML and an MCP client cannot discover the authorization server.
  destinations = [
    { type = "public", uri = "kb.qnsc.vn/mcp" },
    { type = "public", uri = "kb.qnsc.vn/.well-known/oauth-authorization-server" },
  ]
  session_duration = "24h" # the OAuth GRANT session (MCP-PLAN §5)
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  # Managed OAuth: Access is the OAuth server for this app. Redirect URIs a dynamically
  # registered client may use: claude.ai, the MCP portal's admin authorization (dashboard
  # callback, per account and server) and the shared Cloudflare callback the portal uses per
  # user (is_shared_oauth_callback_enabled on the server). Localhost/loopback for Claude Code.
  oauth_configuration = {
    enabled = true
    dynamic_client_registration = {
      enabled                = true
      allow_any_on_localhost = true
      allow_any_on_loopback  = true
      allowed_uris = [
        "https://claude.ai/api/mcp/auth_callback",
        "https://dash.cloudflare.com/${var.cloudflare_account_id}/one/access-controls/ai-controls/mcp-server/oauth-callback/kb-prod",
        "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
      ]
    }
    grant = {
      access_token_lifetime = "15m"
    }
  }

  policies = [{
    id         = cloudflare_zero_trust_access_policy.kb_prod_mcp_allow[0].id
    precedence = 1
  }]
}

# The upstream kb prod MCP server, OAuth (per-user). No credentials in code or state: the
# gateway registers itself with the upstream's Managed OAuth (DCR).
resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "kb_prod" {
  count = local.kb_prod_in_portal ? 1 : 0

  account_id  = var.cloudflare_account_id
  id          = "kb-prod"
  name        = "kb-prod"
  description = "KB prod MCP server (per-user OAuth)"
  hostname    = "https://kb.qnsc.vn/mcp"
  auth_type   = "oauth"
  # Per-user OAuth redirects through the one Cloudflare-owned callback (allowed on the upstream app).
  is_shared_oauth_callback_enabled = true
  # Cloudflare provider 5.28.1 bug: every plan shows this server "updated in-place" from computed
  # fields only (tools, last_synced, authentication_status) and the apply PUTs `updated_tools: null`,
  # which the API refuses. Nothing here is meant to drift, so the resource is frozen after create.
  # To change hostname/auth on purpose: remove this block in that PR (or `-replace`), and put it back
  # once the provider is fixed.
  lifecycle {
    ignore_changes = all
  }
}

resource "cloudflare_zero_trust_access_application" "kb_prod_mcp_via_portal" {
  count = local.kb_prod_in_portal ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "kb-prod MCP server (via portal)"
  type             = "mcp"
  session_duration = "24h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  destinations = [{
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.kb_prod[0].id
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.kb_prod_mcp_allow[0].id
    precedence = 1
  }]
}

# No cloudflare_workers_route: kb.qnsc.vn has web = "cluster" (no SPA Worker), so the
# tunnel owns every path. The /mcp rule is in live/onprem/tunnels.tf before the catch-all.

output "kb_prod_mcp_aud" {
  description = "AUD tag of the kb-prod /mcp Access app. Copy into kv-qnsc-prod/kb-prod-mcp-access-aud before the gitops MCP env change merges."
  value       = one(cloudflare_zero_trust_access_application.kb_prod_mcp[*].aud)
}
