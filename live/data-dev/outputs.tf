output "postgres_host" {
  value       = module.postgres.endpoint
  description = "Passed to product-profile as `shared_postgres.host` for every dev product (§5d)."
}

output "postgres_identifier" {
  value = module.postgres.identifier
}

output "preview_postgres_host" {
  value       = module.postgres_preview.endpoint
  description = <<-EOT
    §11 — a database per pull request lives here, NOT on the dev instance.
    "Previews must not pollute dev data", and a preview runs migrations from an
    unreviewed branch.
  EOT
}

output "cache_host" {
  value       = module.cache.endpoint
  description = <<-EOT
    One instance, database index per product (§5d):
      db 0  qnsc-kb   Celery broker
      db 1  qnsc-kb   rate limiting
      db 2  rova      platform-cache
      db 3  opshub    platform-cache
  EOT
}
