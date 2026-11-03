# ── rova DEV /mcp — Access app for the MCP server (MCP-PLAN v0.4 §5, §10; AI-4)
#
# Provider v5 now exposes `oauth_configuration` on access_application, but the
# Managed OAuth specifics remain DOCUMENTED OWNER CLICK-STEPS (below). This
# file creates the per-server Access app + policy that gate the path; the MCP
# portal and the portal-side server registration are in mcp_portal.tf. Until those clicks happen, the app behaves as a plain self-hosted
# Access app: the /mcp path demands an Access session — Claude Code cannot
# complete OAuth yet, and MCP_ENABLED stays false (agent C owns that flag).
#
# Gate: local.cutover, same as every rova-dev resource — nothing exists for
# the host until its move apply.
#
# Policy group: `grp-qnsc-developers` — the SAME Entra group the web dev
# Access app allows (the rova users group). VLSI stays excluded at group
# membership (MCP-PLAN §5 L1).

resource "cloudflare_zero_trust_access_application" "rova_dev_mcp" {
  count = contains(local.cutover_live, "rova-dev.qnsc.vn") ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "rova-dev MCP server"
  domain     = "rova-dev.qnsc.vn/mcp"
  type       = "self_hosted"

  # Access serves the OAuth metadata at <host>/.well-known/oauth-authorization-server (Managed OAuth). That
  # path must belong to this app, or the SPA Worker / the web app answers it with HTML and an MCP client
  # (the portal's server registration included) cannot discover the authorization server.
  destinations = [
    { type = "public", uri = "rova-dev.qnsc.vn/mcp" },
    { type = "public", uri = "rova-dev.qnsc.vn/.well-known/oauth-authorization-server" },
  ]
  session_duration = "24h" # the OAuth GRANT session (MCP-PLAN §5: chosen 24 h)
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  # Managed OAuth (was a dashboard click-step): Access is the OAuth server for this app. Redirect URIs a
  # dynamically registered client may use: claude.ai, the MCP portal's admin authorization (dashboard
  # callback, per account and server) and the shared Cloudflare callback the portal uses per user
  # (is_shared_oauth_callback_enabled on the server). Localhost/loopback for Claude Code.
  oauth_configuration = {
    enabled = true
    dynamic_client_registration = {
      enabled                = true
      allow_any_on_localhost = true
      allow_any_on_loopback  = true
      allowed_uris = [
        "https://claude.ai/api/mcp/auth_callback",
        "https://dash.cloudflare.com/${var.cloudflare_account_id}/one/access-controls/ai-controls/mcp-server/oauth-callback/rova-dev",
        "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
      ]
    }
    grant = {
      access_token_lifetime = "15m"
    }
  }

  policies = [{
    id         = cloudflare_zero_trust_access_policy.rova_dev_mcp_allow[0].id
    precedence = 1
  }]
}

# v5 shape: policy defined standalone (no application_id/zone_id/precedence —
# attachment happens on the application's `policies` above); `azure` became
# `azure_ad`; include/require are attributes, not blocks.
resource "cloudflare_zero_trust_access_policy" "rova_dev_mcp_allow" {
  count = contains(local.cutover_live, "rova-dev.qnsc.vn") ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "rova-dev-mcp-mfa"
  decision         = "allow"
  session_duration = "24h"

  include = [{
    azure_ad = {
      id                   = var.grp_developers_id
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }]
  require = [{
    auth_method = { auth_method = "mfa" }
  }]
}

# ── OWNER CLICK-STEPS (what is left after Managed OAuth moved into IaC, 2026-11-03) ──
#
# Managed OAuth (redirect URIs, localhost/loopback, 15 min tokens) is `oauth_configuration` above.
# Still manual, once per MCP server after a create (needs an interactive OAuth login):
#   Zero Trust → Access controls → MCP Portals → <server> → Edit → Server authentication:
#   Automatic → Authenticate server (Entra, a member of grp-qnsc-developers) → enable the tools → Save.
#   Status turns Active; until then the portal answers "No allowed servers available".

# ── MCP Server Portal `qnsc` — now IaC: see mcp_portal.tf. The claude.ai
# connector (portal URL) is added once by the Claude Team Owner (CEO).

# Post-apply verification (gate b on the real host, MCP-PLAN §9):
#   curl -s https://rova-dev.qnsc.vn/mcp/.well-known/oauth-authorization-server | jq .
#   → JSON metadata (NOT index.html, NOT an Access login page). The 401
#   WWW-Authenticate resource_metadata carries the protected-resource metadata.

# The AUD tag the rova app must verify (MCP-PLAN §5: JWKS + iss + aud). The
# cutover config (agent C) consumes this output — put it in the rova-dev app
# bundle as the MCP audience, alongside the CF-Access team domain.
output "rova_dev_mcp_aud" {
  description = "AUD tag of the rova-dev /mcp Access app — the audience the app's Access-JWT verifier pins. Consumed at cutover (agent C)."
  value       = one(cloudflare_zero_trust_access_application.rova_dev_mcp[*].aud)
}
