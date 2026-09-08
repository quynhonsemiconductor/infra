# Consumed by the rally product stacks via terraform_remote_state
# (platform/storage-dev) — injected into the api/worker tasks as
# S3_ATTACHMENTS_BUCKET + STORAGE_ENDPOINT. null when the stack is applied
# plan-only (no cloudflare_account_id).
output "rally_attachments_name" {
  value       = one(module.rally_attachments[*].name)
  description = "rova-develop R2 attachments bucket name (inject as S3_ATTACHMENTS_BUCKET)."
}

output "rally_attachments_endpoint" {
  value       = one(module.rally_attachments[*].endpoint)
  description = "rova-develop R2 S3-compatible API endpoint (inject as STORAGE_ENDPOINT)."
}

# Consumed by the opshub product stacks via terraform_remote_state
# (platform/storage-dev) — injected into the api/worker tasks as
# S3_ATTACHMENTS_BUCKET + STORAGE_ENDPOINT. null when applied plan-only.
output "opshub_attachments_name" {
  value       = one(module.opshub_attachments[*].name)
  description = "opshub-develop R2 attachments bucket name (inject as S3_ATTACHMENTS_BUCKET)."
}

output "opshub_attachments_endpoint" {
  value       = one(module.opshub_attachments[*].endpoint)
  description = "opshub-develop R2 S3-compatible API endpoint (inject as STORAGE_ENDPOINT)."
}

output "rally_public_assets_name" {
  value       = one(module.rally_public_assets[*].name)
  description = "rova-develop R2 public-assets bucket name (inject as S3_PUBLIC_ASSETS_BUCKET)."
}

output "rally_public_assets_base_url" {
  value       = one(module.rally_public_assets[*].public_base_url)
  description = <<-EOT
    Public HTTPS origin for rova-develop public assets — inject as
    CDN_PUBLIC_ASSETS_BASE_URL. Null until `custom_domain` is attached, and the API
    returns 409 on every avatar upload while it is null.

    ONLY ever from the public-assets bucket. This origin serves objects to anyone
    who knows the key, so wiring it from an attachments bucket would silently make
    every permission-gated file world-readable.
  EOT
}

# Rebrand aliases: the product stack now looks these up under the `rova_*` prefix
# (var.product = "rova"). They point at the SAME underlying R2 buckets — the
# physical bucket names are intentionally unchanged to avoid an object-data
# migration. Rename the physical buckets separately if/when desired.
output "rova_attachments_name" {
  value       = one(module.rally_attachments[*].name)
  description = "Alias of rally_attachments_name for the rebranded product stack."
}

output "rova_attachments_endpoint" {
  value       = one(module.rally_attachments[*].endpoint)
  description = "Alias of rally_attachments_endpoint for the rebranded product stack."
}

output "rova_public_assets_name" {
  value       = one(module.rally_public_assets[*].name)
  description = "Alias of rally_public_assets_name for the rebranded product stack."
}

output "rova_public_assets_base_url" {
  value       = one(module.rally_public_assets[*].public_base_url)
  description = "Alias of rally_public_assets_base_url for the rebranded product stack."
}

# Consumed by the qnsc-kb develop stack via terraform_remote_state
# (platform/storage-dev) — injected into the api/worker tasks as
# SOURCE_STORAGE_BUCKET + S3_ENDPOINT_URL, alongside SOURCE_STORAGE_BACKEND="r2".
# null when the stack is applied plan-only (no cloudflare_account_id).
output "qnsc_kb_sources_name" {
  value       = one(module.qnsc_kb_sources[*].name)
  description = "qnsc-kb-develop R2 sources bucket name (inject as SOURCE_STORAGE_BUCKET)."
}

output "qnsc_kb_sources_endpoint" {
  value       = one(module.qnsc_kb_sources[*].endpoint)
  description = <<-EOT
    qnsc-kb-develop R2 S3-compatible API endpoint (inject as S3_ENDPOINT_URL).

    The app's config validator accepts either this or R2_ACCOUNT_ID; passing the
    endpoint is preferred because it is an output of the resource itself, so it
    cannot drift from the bucket it addresses.
  EOT
}
