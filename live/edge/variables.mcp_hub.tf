# MCP hub (MCP-PLAN §10 P1.5): third-party upstream servers behind the portal
# `qnsc`. Everything defaults to OFF/empty, so merging this changes nothing
# until the owner has created the OAuth apps and set the CI values (runbook:
# product-docs platform/mcp/HUB-SETUP.md).

variable "mcp_hub_enabled" {
  type        = bool
  default     = false
  description = "Create the GitHub and Grafana Cloud servers in the MCP portal. TF_VAR_mcp_hub_enabled (repo variable MCP_HUB_ENABLED). Needs mcp_github_oauth_client_id and mcp_github_oauth_client_secret."
}

variable "mcp_github_oauth_client_id" {
  type        = string
  default     = ""
  description = "Client id of the GitHub OAuth App \"QNSC MCP\" (public by design). TF_VAR_mcp_github_oauth_client_id (repo variable MCP_GITHUB_OAUTH_CLIENT_ID)."
}

variable "mcp_github_oauth_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Client secret of that GitHub OAuth App, created out-of-band (owner, stdin). Lands in the CF state like the Entra IdP secret (documented exception). TF_VAR_mcp_github_oauth_client_secret (environment secret MCP_GITHUB_OAUTH_CLIENT_SECRET)."
}

variable "mcp_grafana_oauth_client_id" {
  type        = string
  default     = ""
  description = "Empty = Cloudflare registers itself at Grafana Cloud MCP by DCR (try this first). Only if DCR fails: the client id of a manually registered Grafana OAuth client. TF_VAR_mcp_grafana_oauth_client_id."
}

variable "mcp_grafana_oauth_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Secret of the manually registered Grafana OAuth client (only with mcp_grafana_oauth_client_id). TF_VAR_mcp_grafana_oauth_client_secret (environment secret MCP_GRAFANA_OAUTH_CLIENT_SECRET)."
}

variable "mcp_grafana_authorization_endpoint" {
  type        = string
  default     = ""
  description = "Authorization endpoint from the Grafana \"OAuth setup\" panel (manual client only)."
}

variable "mcp_grafana_token_endpoint" {
  type        = string
  default     = ""
  description = "Token endpoint from the Grafana \"OAuth setup\" panel (manual client only)."
}
