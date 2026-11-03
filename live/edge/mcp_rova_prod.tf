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
# POLICY GROUPS: grp-qnsc-staff (every employee; owner decision 2026-11-03: rova is an internal tool for the whole
# company) plus grp-qnsc-developers and grp-qnsc-dev-users, kept so nobody loses access before staff is populated.
# rova's RBAC (the signed-in user) still decides every call.
#
# ORDER: apply this stack FIRST; read the new app's AUD (output rova_prod_mcp_aud) into
# kv-qnsc-prod/rova-prod-mcp-access-aud; ONLY THEN merge the gitops change that sets MCP_ENABLED=true
# (the API refuses to boot with MCP on and no audience).
#
# OWNER CLICK-STEP: authenticate the server once in the MCP portal (see mcp.tf); Managed OAuth is IaC.
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

  # grp-qnsc-staff (everyone) + developers + dev-users: the rova tools act as the signed-in rova user, so rova's
  # own RBAC still decides what each person can read or change. Include = OR.
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

resource "cloudflare_zero_trust_access_application" "rova_prod_mcp" {
  count = local.rova_prod_mcp_live ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "rova-prod MCP server"
  domain     = "rova.qnsc.vn/mcp"
  type       = "self_hosted"

  # Access serves the OAuth metadata at <host>/.well-known/oauth-authorization-server (Managed OAuth). That
  # path must belong to this app, or the SPA Worker / the web app answers it with HTML and an MCP client
  # (the portal's server registration included) cannot discover the authorization server.
  destinations = [
    { type = "public", uri = "rova.qnsc.vn/mcp" },
    { type = "public", uri = "rova.qnsc.vn/.well-known/oauth-authorization-server" },
  ]
  session_duration = "24h" # the OAuth GRANT session (MCP-PLAN §5)
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
        "https://dash.cloudflare.com/${var.cloudflare_account_id}/one/access-controls/ai-controls/mcp-server/oauth-callback/rova-prod",
        "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
      ]
    }
    grant = {
      access_token_lifetime = "15m"
    }
  }

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
