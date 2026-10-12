variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = <<-EOT
    Cloudflare API token with Account:Workers R2 Storage edit scope (creates the
    buckets + their CORS/lifecycle config). Supplied via TF_VAR_cloudflare_api_token
    in CI. This is the provisioning token only — NOT the bucket-scoped runtime
    token the app uses (that lives in each product's Secrets Manager). Leave
    empty to skip provider auth for plan-only bootstrapping.
  EOT
}

variable "cloudflare_account_id" {
  type        = string
  default     = ""
  description = <<-EOT
    Cloudflare account ID that owns the R2 buckets. Supplied via
    TF_VAR_cloudflare_account_id in CI from the CLOUDFLARE_ACCOUNT_ID Actions
    VARIABLE (not a secret — the workflows read `vars.CLOUDFLARE_ACCOUNT_ID`, and
    an account ID is not sensitive). Pairs with the CLOUDFLARE_API_TOKEN secret.
    Leave empty only for plan-only bootstrapping — the bucket modules are gated
    on it.
  EOT
}

variable "cloudflare_zone_id" {
  type        = string
  description = <<-EOT
    Cloudflare zone id of qnsc.vn: 32 hex characters, REQUIRED (no default). CI passes it as TF_VAR_cloudflare_zone_id
    from the CLOUDFLARE_ZONE_ID organisation variable. It is the identity of the public-assets custom domain
    (an R2 custom domain whose zone_id forces replacement), so an empty or malformed value must stop the plan.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be the 32-hex-character Cloudflare zone id of qnsc.vn (CI: the CLOUDFLARE_ZONE_ID organisation variable)."
  }
}
