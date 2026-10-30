# ── rova DEV /mcp — Access app for the MCP server (MCP-PLAN v0.4 §5, §10; AI-4)
#
# Provider v5 now exposes `oauth_configuration` on access_application, but the
# Managed OAuth + MCP-portal rollout stays QUEUED (SA 2026-10-27 — do not
# start it here). So this file only creates the Access app + policy that gate
# the path, and the Managed OAuth specifics remain DOCUMENTED OWNER CLICK-STEPS
# (below). Until those clicks happen, the app behaves as a plain self-hosted
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

  account_id       = var.cloudflare_account_id
  name             = "rova-dev MCP server"
  domain           = "rova-dev.qnsc.vn/mcp"
  type             = "self_hosted"
  session_duration = "24h" # the OAuth GRANT session (MCP-PLAN §5: chosen 24 h)
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

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

# ── OWNER CLICK-STEPS (Managed OAuth — queued, not in IaC) ──────────────────
#
# After this app is applied, in Zero Trust → Access → Applications →
# "rova-dev MCP server":
#   1. Managed OAuth: ON.
#   2. Redirect URIs: the claude.ai callback (https://claude.ai/api/mcp/auth_callback)
#      and LOOPBACK clients enabled (http://localhost:* — Claude Code).
#   3. Access token lifetime: 15 minutes.
#      (The 24 h grant = `session_duration` above, already in IaC.)
#   4. Confirm IdP = Entra only; policy = the group + MFA policy from this file.
#
# ── MCP Server Portal "QNSC" ─────────────────────────────────────────────────
#
# NOT expressible in this provider version (no portal resource). Owner
# console steps (Zero Trust → Access → MCP Server Portal):
#   1. Create portal, name "QNSC".
#   2. Add server: rova-dev /mcp (pick the Access app created above).
#   3. Portal login = Entra via Access; per-server policies gate visibility.
# Until the portal exists, members connect to the per-server Access app
# directly — the fallback path, identical rights.

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
