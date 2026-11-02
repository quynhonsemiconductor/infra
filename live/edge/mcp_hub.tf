# ── MCP hub: GitHub + Grafana Cloud behind the portal `qnsc` (MCP-PLAN §10) ──
#
# Every server is per-user OAuth ("Require user auth" = on_behalf = true, never
# false: a shared credential would hide who did what, MCP-PLAN §5). Visibility
# is gated per server by an Access app (type mcp, via_mcp_server_portal) with a
# group + MFA policy; the portal login policy (mcp_portal.tf) only admits
# @qnsc.vn. Gate: var.mcp_hub_enabled AND the portal gate.
#
# GitHub (no DCR): ONE pre-registered GitHub OAuth App "QNSC MCP" shared by
# three READ-ONLY toolset endpoints (the path form accepts a single toolset;
# /readonly is enforced by GitHub). The shared Cloudflare callback is used, so
# the OAuth App has one callback URL regardless of server count:
#   https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback
# (from the Cloudflare docs — the owner verifies it in the dashboard server
# page before creating the GitHub OAuth App; HUB-SETUP.md).
# Note: a GitHub OAuth App scope `repo` is not read-only by itself; the
# read-only guarantee comes from the /readonly endpoint, and the org approves
# the app in its OAuth app policy.
#
# Grafana Cloud: DCR first (no credentials). A manual client is wired only when
# mcp_grafana_oauth_client_id is set.

locals {
  mcp_hub_live = local.mcp_portal_live && var.mcp_hub_enabled

  mcp_github_toolsets = local.mcp_hub_live ? toset(["repos", "issues", "pull_requests"]) : toset([])

  mcp_grafana_manual = var.mcp_grafana_oauth_client_id != ""
}

resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "github" {
  for_each = local.mcp_github_toolsets

  account_id  = var.cloudflare_account_id
  id          = "github-${replace(each.key, "_", "-")}"
  name        = "github-${replace(each.key, "_", "-")}"
  description = "GitHub ${each.key} (read-only), per-user OAuth"
  hostname    = "https://api.githubcopilot.com/mcp/x/${each.key}/readonly"
  auth_type   = "oauth"

  auth_credentials = jsonencode({
    auth_mode = "manual"
    config = {
      authorization_endpoint = "https://github.com/login/oauth/authorize"
      token_endpoint         = "https://github.com/login/oauth/access_token"
    }
    registration_info = {
      client_id                  = var.mcp_github_oauth_client_id
      scope                      = "repo read:org"
      token_endpoint_auth_method = "client_secret_post"
    }
  })
  client_secret                    = var.mcp_github_oauth_client_secret
  is_shared_oauth_callback_enabled = true

  lifecycle {
    precondition {
      condition     = var.mcp_github_oauth_client_id != "" && var.mcp_github_oauth_client_secret != ""
      error_message = "mcp_hub_enabled needs mcp_github_oauth_client_id and mcp_github_oauth_client_secret (HUB-SETUP.md)."
    }
  }
}

resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "grafana" {
  count = local.mcp_hub_live ? 1 : 0

  account_id  = var.cloudflare_account_id
  id          = "grafana"
  name        = "grafana"
  description = "Grafana Cloud MCP, per-user OAuth"
  hostname    = "https://mcp.grafana.com/mcp"
  auth_type   = "oauth"

  auth_credentials = local.mcp_grafana_manual ? jsonencode({
    auth_mode = "manual"
    config = {
      authorization_endpoint = var.mcp_grafana_authorization_endpoint
      token_endpoint         = var.mcp_grafana_token_endpoint
    }
    registration_info = {
      client_id                  = var.mcp_grafana_oauth_client_id
      token_endpoint_auth_method = "client_secret_post"
    }
  }) : null
  client_secret                    = local.mcp_grafana_manual ? var.mcp_grafana_oauth_client_secret : null
  is_shared_oauth_callback_enabled = local.mcp_grafana_manual ? true : null

  lifecycle {
    precondition {
      condition = !local.mcp_grafana_manual || (
        var.mcp_grafana_oauth_client_secret != "" &&
        var.mcp_grafana_authorization_endpoint != "" &&
        var.mcp_grafana_token_endpoint != ""
      )
      error_message = "a manual Grafana client needs its secret and both endpoints (HUB-SETUP.md)."
    }
  }
}

# Who sees GitHub: developers + platform admins. Who sees Grafana: platform
# admins (on-call). Both require MFA, like every other MCP policy.
resource "cloudflare_zero_trust_access_policy" "mcp_github_allow" {
  count = local.mcp_hub_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "mcp-github-developers-mfa"
  decision         = "allow"
  session_duration = "24h"

  include = [
    {
      azure_ad = {
        id                   = var.grp_developers_id
        identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
      }
    },
    {
      azure_ad = {
        id                   = var.grp_platform_admins_id
        identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
      }
    },
  ]
  require = [{
    auth_method = { auth_method = "mfa" }
  }]
}

resource "cloudflare_zero_trust_access_policy" "mcp_grafana_allow" {
  count = local.mcp_hub_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "mcp-grafana-platform-admins-mfa"
  decision         = "allow"
  session_duration = "24h"

  include = [{
    azure_ad = {
      id                   = var.grp_platform_admins_id
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }]
  require = [{
    auth_method = { auth_method = "mfa" }
  }]
}

resource "cloudflare_zero_trust_access_application" "mcp_github_via_portal" {
  count = local.mcp_hub_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "GitHub MCP servers (via portal)"
  type             = "mcp"
  session_duration = "24h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  destinations = [for k in sort(keys(cloudflare_zero_trust_access_ai_controls_mcp_server.github)) : {
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.github[k].id
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.mcp_github_allow[0].id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_application" "mcp_grafana_via_portal" {
  count = local.mcp_hub_live ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "Grafana MCP server (via portal)"
  type             = "mcp"
  session_duration = "24h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  destinations = [{
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.grafana[0].id
  }]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.mcp_grafana_allow[0].id
    precedence = 1
  }]
}
