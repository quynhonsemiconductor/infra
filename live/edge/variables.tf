variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = <<-EOT
    Cloudflare API token with Zone:WAF + Zone:Rulesets + Zone:DNS edit scope on
    qnsc.vn (DNS:Edit is needed to write the ACM validation records). Supplied
    via TF_VAR_cloudflare_api_token in CI. Leave empty to skip provider auth.
  EOT
}

variable "cloudflare_zone_id" {
  type        = string
  description = <<-EOT
    Cloudflare zone id of qnsc.vn: 32 hex characters, REQUIRED (no default). CI passes it as TF_VAR_cloudflare_zone_id
    from the CLOUDFLARE_ZONE_ID organisation variable. It is the identity of every DNS record in this stack, so an
    empty or malformed value must stop the plan: the records would otherwise be replaced.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be the 32-hex-character Cloudflare zone id of qnsc.vn (CI: the CLOUDFLARE_ZONE_ID organisation variable)."
  }
}

variable "certificate_domain" {
  type        = string
  default     = "qnsc.vn"
  description = "Apex domain for the shared wildcard ACM certificate. The cert covers *.<domain> and <domain>, fronting every product API on the shared ALB."
}

variable "enable_managed_waf" {
  type = bool
  # Owner decision 2026-11-01: run the FREE managed ruleset on the zone. The
  # module's default list (Pro Managed + OWASP) is refused on this plan ("not
  # entitled", CI plan 2026-11-01); the call site passes the free id instead.
  default     = true
  description = "Deploy Cloudflare Managed + OWASP rulesets (Pro+ plan only). When enabling for prod, drop the AWS waf module from runtime-prod."
}

variable "custom_firewall_rules" {
  type = list(object({
    ref         = string
    description = string
    expression  = string
    action      = string
  }))
  default     = []
  description = "Optional custom expression firewall rules passed through to the cf-edge module."
}

variable "cloudflare_account_id" {
  type        = string
  description = <<-EOT
    Cloudflare account ID that owns the qnsc.vn zone and hosts the Pages projects: 32 hex characters, REQUIRED (no default). CI passes it as
    TF_VAR_cloudflare_account_id from the CLOUDFLARE_ACCOUNT_ID Actions VARIABLE (not a secret). It used to default to ""
    ("leave empty for plan-only bootstrapping") and the Pages project, its domains and the Turnstile widget needed it; an empty value therefore planned to DESTROY the landing Pages project and its domains, so it is
    now an error instead.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be the 32-hex-character Cloudflare account id (CI: the CLOUDFLARE_ACCOUNT_ID Actions variable)."
  }
}

variable "warp_extra_excludes" {
  description = "Extra WARP split-tunnel excludes for the platform-admins profile, e.g. a partner's WireGuard endpoint (/32), so another VPN is not tunnelled inside WARP. JSON from the WARP_EXTRA_EXCLUDES secret (public repo: partner addresses stay out of code and logs)."
  type = list(object({
    address     = string
    description = string
  }))
  default = []
  validation {
    condition     = alltrue([for e in var.warp_extra_excludes : can(cidrhost(e.address, 0)) && length(e.description) > 0])
    error_message = "Each warp_extra_excludes entry needs a CIDR address (use /32 for one host) and a description."
  }
}

# The live id of the Coder private hostname route, adopted by the import block in coder.tf. An identifier,
# not a secret (repo variable CODER_HOSTNAME_ROUTE_ID, like the Entra group ids). Empty = no import; the
# route is then created by the plan, which the API rejects with 409 when it already exists — so set it
# before the first edge plan that includes coder.tf.
variable "coder_hostname_route_id" {
  type        = string
  default     = ""
  description = "Hostname-route UUID of the live coder.qnsc.vn route (adopted, not created). TF_VAR_coder_hostname_route_id (repo variable CODER_HOSTNAME_ROUTE_ID)."

  validation {
    condition     = var.coder_hostname_route_id == "" || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.coder_hostname_route_id))
    error_message = "coder_hostname_route_id must be empty or a UUID (the route id, without the account prefix)."
  }
}
