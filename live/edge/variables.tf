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
  type        = bool
  default     = false
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

variable "mail_domain" {
  type        = string
  default     = "qnsc.vn"
  description = "Domain SES verifies for outbound mail across every product. One identity covers all of them because they share the account and region."
}

variable "mail_region" {
  type        = string
  default     = "ap-southeast-1"
  description = "Region whose SES sends the mail. Only used to build the custom MAIL FROM MX host (feedback-smtp.<region>.amazonses.com), which is region-specific — a wrong value silently loses bounce notifications rather than failing loudly."
}

variable "cloudflare_account_id" {
  type        = string
  default     = ""
  description = <<-EOT
    Cloudflare account ID that owns the qnsc.vn zone and hosts the Pages
    projects (static sites). Supplied via TF_VAR_cloudflare_account_id in CI
    from the CLOUDFLARE_ACCOUNT_ID org secret — the same account as
    cloudflare_api_token. Leave empty only for plan-only bootstrapping without
    Pages resources.
  EOT
}
