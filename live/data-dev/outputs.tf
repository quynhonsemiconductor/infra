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

# The RDS-MANAGED master password, passed on by ARN rather than by name.
#
# ⚠ THIS DID NOT EXIST, and its absence broke every product stack. `rova-dev` and
# `kb-dev` each read a HAND-MADE secret called `qnsc/dev/platform/postgres-admin`
# which nothing in this estate creates — so their plans failed on a data source
# for a secret that was never there. Three separate faults in one block, found
# 2026-09-22 by querying AWS rather than reading the code:
#
#   the secret          did not exist. `manage_master_user_password = true` means
#                       RDS owns it, under a generated name like
#                       `rds!db-8d3f452a-…`, and this output is how a caller finds it
#   the username        was hardcoded `qnsc_admin`. The real master user is
#                       `app_admin` — modules/rds's `master_username` default
#   the shape           was treated as a bare password. An RDS-managed secret is
#                       JSON: {"username": …, "password": …}
#
# Passing the ARN rather than a name matters for a reason beyond tidiness: RDS
# ROTATES this secret. A hand-copied duplicate goes stale silently and the failure
# arrives as an authentication error on a connection that used to work.
output "postgres_admin_secret_arn" {
  value       = module.postgres.master_secret_arn
  description = "ARN of the RDS-managed master password secret. JSON: {username, password}."
  sensitive   = true
}
