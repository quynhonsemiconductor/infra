# ── rova DEV /mcp — Access app for the MCP server (MCP-PLAN v0.4 §5, §10; AI-4)
#
# Provider 4.52.9 CANNOT express Managed OAuth (no oauth_configuration on
# access_application, no MCP-portal resource — verified against the provider
# schema). So this file creates the Access app + policy that gate the path,
# and the Managed OAuth specifics are DOCUMENTED OWNER CLICK-STEPS (below and
# in the PR body). Until those clicks happen, the app behaves as a plain
# self-hosted Access app: the /mcp path demands an Access session — Claude
# Code cannot complete OAuth yet, and MCP_ENABLED stays false (agent C owns
# that flag).
#
# Gate: cutover_hosts, same as every rova-dev resource — nothing exists for
# the host until its move apply.
#
# Policy group: `grp-qnsc-developers` — the SAME Entra group the web dev
# Access app allows (the rova users group). VLSI stays excluded at group
# membership (MCP-PLAN §5 L1).

resource "cloudflare_zero_trust_access_application" "rova_dev_mcp" {
  count = var.tunnels_exist && contains(var.cutover_hosts, "rova-dev.qnsc.vn") ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "rova-dev MCP server"
  domain           = "rova-dev.qnsc.vn/mcp"
  type             = "self_hosted"
  session_duration = "24h" # the OAuth GRANT session (MCP-PLAN §5: chosen 24 h)
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]
}

resource "cloudflare_zero_trust_access_policy" "rova_dev_mcp_allow" {
  count = var.tunnels_exist && contains(var.cutover_hosts, "rova-dev.qnsc.vn") ? 1 : 0

  account_id       = var.cloudflare_account_id
  zone_id          = var.cloudflare_zone_id
  application_id   = cloudflare_zero_trust_access_application.rova_dev_mcp[0].id
  name             = "rova-dev-mcp-mfa"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    azure {
      id                   = [var.grp_developers_id]
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }
  require {
    auth_method = "mfa"
  }
}

# ── OWNER CLICK-STEPS (provider 4.52.9 cannot express these) ────────────────
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
