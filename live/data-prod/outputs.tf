output "postgres_host" {
  value       = module.postgres.endpoint
  description = <<-EOT
    Passed to product-profile as `shared_postgres.host` for opshub, LMS, solodesk
    and ai-dev-kit. rova and qnsc-kb are dedicated and create their own (§5).
  EOT
}

output "postgres_identifier" {
  value = module.postgres.identifier
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
