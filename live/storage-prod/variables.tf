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
  description = <<-EOT
    Cloudflare account ID that owns the R2 buckets: 32 hex characters, REQUIRED (no default). CI passes it as
    TF_VAR_cloudflare_account_id from the CLOUDFLARE_ACCOUNT_ID Actions VARIABLE (not a secret). It used to default to ""
    ("leave empty for plan-only bootstrapping") and the bucket modules were gated on it (count = 0); an empty value therefore planned to DESTROY every R2 bucket, its CORS and lifecycle rules, and the public-assets custom domain, so it is
    now an error instead.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be the 32-hex-character Cloudflare account id (CI: the CLOUDFLARE_ACCOUNT_ID Actions variable)."
  }
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
