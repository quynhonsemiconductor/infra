output "role_settings_sql" {
  value     = module.product.role_settings_sql
  sensitive = false

  description = <<-EOT
    ⚠ APPLY THIS AFTER EVERY APPLY. It is idempotent.

        tofu output -raw role_settings_sql | psql "$ADMIN_URL"

    The cyrilgdn/postgresql provider has no resource for role settings, so
    product-profile emits the SQL rather than pretending to apply it (§6). The
    alternative was a null_resource shelling out to psql, which needs network
    reachability and a client binary inside whatever runs `tofu apply`, and fails
    in a way that leaves state disagreeing with reality.

    UNTIL IT RUNS, nothing bounds a noisy neighbour on the shared instance, and
    the migrator has the 30s application timeout rather than the 600s the Job
    needs (§5d).
  EOT
}

output "irsa_role_arns" {
  value       = module.product.irsa_role_arns
  description = "For humans. The chart derives the same strings (§7c)."
}
