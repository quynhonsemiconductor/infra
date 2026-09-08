# Consumed by the rally product stacks via terraform_remote_state
# (platform/storage-prod) — injected into the api/worker tasks as
# S3_ATTACHMENTS_BUCKET + STORAGE_ENDPOINT. null when the stack is applied
# plan-only (no cloudflare_account_id).
output "rally_attachments_name" {
  value       = one(module.rally_attachments[*].name)
  description = "rova-prod R2 attachments bucket name (inject as S3_ATTACHMENTS_BUCKET)."
}

output "rally_attachments_endpoint" {
  value       = one(module.rally_attachments[*].endpoint)
  description = "rova-prod R2 S3-compatible API endpoint (inject as STORAGE_ENDPOINT)."
}

# Consumed by the opshub product stacks via terraform_remote_state
# (platform/storage-prod) — injected into the api/worker tasks as
# S3_ATTACHMENTS_BUCKET + STORAGE_ENDPOINT. null when applied plan-only.
output "opshub_attachments_name" {
  value       = one(module.opshub_attachments[*].name)
  description = "opshub-prod R2 attachments bucket name (inject as S3_ATTACHMENTS_BUCKET)."
}

output "opshub_attachments_endpoint" {
  value       = one(module.opshub_attachments[*].endpoint)
  description = "opshub-prod R2 S3-compatible API endpoint (inject as STORAGE_ENDPOINT)."
}

output "rally_public_assets_name" {
  value       = one(module.rally_public_assets[*].name)
  description = "rova-prod R2 public-assets bucket name (inject as S3_PUBLIC_ASSETS_BUCKET)."
}

output "rally_public_assets_base_url" {
  value       = one(module.rally_public_assets[*].public_base_url)
  description = <<-EOT
    Public HTTPS origin for rova-prod public assets — inject as
    CDN_PUBLIC_ASSETS_BASE_URL. Null until `custom_domain` is attached, and the API
    returns 409 on every avatar upload while it is null.

    ONLY ever from the public-assets bucket. This origin serves objects to anyone
    who knows the key, so wiring it from an attachments bucket would silently make
    every permission-gated file world-readable.
  EOT
}

# Product-name aliases for the rebranded stack (product = "rova"): the product
# stack resolves storage outputs as `${var.product}_*`. These expose the same
# underlying buckets under the rova_* names so the rova prod stack reads them.
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

# Consumed by ceo-suite CI (web-deploy `d1_backup_bucket`) — durable archive of
# pre-migration D1 exports. null when applied plan-only (no cloudflare_account_id).
output "ceo_suite_db_backups_name" {
  value       = one(module.ceo_suite_db_backups[*].name)
  description = "ceo-suite D1 backup R2 bucket name (set as web-deploy d1_backup_bucket)."
}

# Consumed by the qnsc-kb prod stack via terraform_remote_state (platform/storage-prod) —
# injected as SOURCE_STORAGE_BUCKET + S3_ENDPOINT_URL alongside SOURCE_STORAGE_BACKEND="r2".
output "qnsc_kb_sources_name" {
  value       = one(module.qnsc_kb_sources[*].name)
  description = "qnsc-kb-prod R2 sources bucket name (inject as SOURCE_STORAGE_BUCKET)."
}

output "qnsc_kb_sources_endpoint" {
  value       = one(module.qnsc_kb_sources[*].endpoint)
  description = "qnsc-kb-prod R2 S3-compatible API endpoint (inject as S3_ENDPOINT_URL)."
}
