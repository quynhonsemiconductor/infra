# ── rova PROD /mcp behind the MCP portal `qnsc` (MCP-PLAN P2) ─────────────────
#
# Same pattern as rova-dev (mcp.tf, mcp_portal.tf), for https://rova.qnsc.vn/mcp:
#   1. a path-scoped Access app on rova.qnsc.vn/mcp (direct fallback path), group + MFA policy;
#   2. the upstream registered in portal `qnsc` as `rova-prod`, "Require user auth" ON (on_behalf = true,
#      never false: rova must see one identity per person) and the Access app that secures it via the portal;
#   3. the two no-Worker routes that send /mcp to the tunnel (the SPA Worker holds rova.qnsc.vn/*, and
#      without these /mcp would be answered with the SPA's index.html).
#
# Prod has NO Access app on the rest of rova.qnsc.vn (gitops/infra #843): only the /mcp path is gated.
#
# Gate: contains(local.cutover_live, "rova.qnsc.vn") (live since the move night). Server and portal
# registration additionally need the portal itself (local.mcp_portal_live, the rova-dev gate in
# mcp_portal.tf), because the portal is one shared resource.
#
# POLICY GROUP: grp-qnsc-developers, the same Entra group as rova-dev (the rova users group). Narrow it
# here (a second group in the `include`) if prod MCP should reach fewer people than dev.
#
# ORDER: apply this stack FIRST; read the new app's AUD (output rova_prod_mcp_aud) into
# kv-qnsc-prod/rova-prod-mcp-access-aud; ONLY THEN merge the gitops change that sets MCP_ENABLED=true
# (the API refuses to boot with MCP on and no audience).
#
# OWNER CLICK-STEPS (Managed OAuth, not in IaC; identical to mcp.tf): after the apply, in Zero Trust,
# Access, Applications, "rova-prod MCP server": Managed OAuth ON; redirect URIs
# https://claude.ai/api/mcp/auth_callback and loopback http://localhost:*; access token lifetime 15 min;
# IdP = Entra only.

locals {
  rova_prod_mcp_live  = contains(local.cutover_live, "rova.qnsc.vn")
  rova_prod_in_portal = local.rova_prod_mcp_live && local.mcp_portal_live
}

resource "cloudflare_zero_trust_access_policy" "rova_prod_mcp_allow" {
  count = local.rova_prod_mcp_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "rova-prod-mcp-mfa"
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

resource "cloudflare_zero_trust_access_application" "rova_prod_mcp" {
  count = local.rova_prod_mcp_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "rova-prod MCP server"
  domain           = "rova.qnsc.vn/mcp"
  type             = "self_hosted"
  session_duration = "24h" # the OAuth GRANT session (MCP-PLAN §5)
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.rova_prod_mcp_allow[0].id
    precedence = 1
  }]
}

# The upstream rova prod MCP server, OAuth (per-user). No credentials in code or state: the gateway
# registers itself with the upstream's Managed OAuth (DCR).
resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "rova_prod" {
  count = local.rova_prod_in_portal ? 1 : 0

  account_id  = var.cloudflare_account_id
  id          = "rova-prod"
  name        = "rova-prod"
  description = "rova prod MCP server (per-user OAuth)"
  hostname    = "https://rova.qnsc.vn/mcp"
  auth_type   = "oauth"
}

resource "cloudflare_zero_trust_access_application" "rova_prod_mcp_via_portal" {
  count = local.rova_prod_in_portal ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "rova-prod MCP server (via portal)"
  type             = "mcp"
  session_duration = "24h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  destinations = [{
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.rova_prod[0].id
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.rova_prod_mcp_allow[0].id
    precedence = 1
  }]
}

# /mcp must reach the tunnel (API), not the SPA Worker that owns rova.qnsc.vn/*. Same no-Worker route
# shape as api_no_worker in onprem.tf (script omitted).
resource "cloudflare_workers_route" "rova_prod_mcp" {
  for_each = local.rova_prod_mcp_live ? toset(["/mcp", "/mcp/*"]) : toset([])

  zone_id = var.cloudflare_zone_id
  pattern = "rova.qnsc.vn${each.value}"
  script  = null
}

# The AUD tag the rova app pins (MCP_ACCESS_AUD). Not a credential, but it goes to the vault.
output "rova_prod_mcp_aud" {
  description = "AUD tag of the rova-prod /mcp Access app. Copy into kv-qnsc-prod/rova-prod-mcp-access-aud before the gitops MCP_ENABLED change merges."
  value       = one(cloudflare_zero_trust_access_application.rova_prod_mcp[*].aud)
}
