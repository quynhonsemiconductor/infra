# Bootstrap is mostly zero-input (it creates the account-level singletons), but
# a few account-wide facts that products need to read live here so there's ONE
# source of truth exported via remote state (like kms_key_arn, oidc_provider_arn).

variable "cloudflare_zone_id" {
  type = string
  # NO DEFAULT, deliberately. It used to default to "" ("leave empty to skip DNS wiring org-wide"), so any apply that
  # did not pass TF_VAR_cloudflare_zone_id (a local `tofu apply`, a job without the variable) silently wrote "" to the
  # output below, and every stack that read it then planned to REPLACE its DNS records. That is how the 9 records of
  # live/edge were destroyed on 2026-10-09 (docs/incidents/2026-10-09-edge-dns.md). A missing value must stop the plan,
  # not become an empty string.
  description = <<-EOT
    Cloudflare Zone ID for the qnsc.vn zone: 32 hex characters. One zone serves every product, so it's an account-level
    fact exported here. CI passes it as TF_VAR_cloudflare_zone_id from the CLOUDFLARE_ZONE_ID organisation variable;
    for a local run, pass the same value (Cloudflare dashboard > qnsc.vn > Overview > API). Not sensitive.
    Stacks in THIS repository take the id from their own validated variable, not from this output; the output remains
    for the product repositories (rova, opshub, qnsc-kb) that read it through their _shared stacks.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be the 32-hex-character Cloudflare zone id of qnsc.vn (CI: the CLOUDFLARE_ZONE_ID organisation variable). An empty or malformed value would make every consumer replace its DNS records."
  }
}
