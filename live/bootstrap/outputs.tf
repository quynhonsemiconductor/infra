output "state_bucket_name" {
  value       = module.state_backend.bucket_name
  description = "Use in all product infra backends: bucket = \"qnsc-tofu-state\""
}

output "dynamodb_table_name" {
  value       = module.state_backend.table_name
  description = "Use in all product infra backends: dynamodb_table = \"qnsc-tofu-locks\""
}

output "oidc_provider_arn" {
  value       = module.oidc_provider.arn
  description = "GitHub OIDC provider ARN — discovered automatically by product infra via data source"
}

output "kms_key_arn" {
  value       = module.kms.key_arn
  description = "Shared CMK ARN — pass to RDS kms_key_id, Secrets Manager kms_key_id, S3 SSE"
}

output "kms_key_alias" {
  value       = module.kms.key_alias
  description = "KMS key alias (alias/qnsc-platform)"
}

output "artifacts_bucket_name" {
  value       = module.artifacts_bucket.bucket_name
  description = "Shared artifacts bucket name — use as s3-bucket in publish-openapi-spec CI action"
}

output "artifacts_bucket_arn" {
  value       = module.artifacts_bucket.bucket_arn
  description = "Shared artifacts bucket ARN — grant product IAM roles write access to their prefix"
}

output "cloudflare_zone_id" {
  value       = var.cloudflare_zone_id
  description = "Cloudflare Zone ID for qnsc.vn — products read this to manage their own DNS records via the shared dns-record module"
}

output "cloudflare_ipv4" {
  value       = local.cloudflare_ipv4
  description = "Cloudflare IPv4 ranges — products read this for prod ALB ingress allow-lists (single source of truth)"
}

# Task 1.8, §11c — the OCI repository `gitops/appsets/products.yaml` gives every
# Application as its chart source, and the one `chart-release.yaml` pushes to.
#
# Exposed as an output rather than left to be read off the console because two
# different things must agree on it and neither reads the other: the
# ApplicationSet's `repoURL`/`chart` pair, and the ARN in ArgoCD's chart-pull
# policy (`cluster-prod/iam.tf`). A disagreement is a sync failure at source
# resolution, which does not name the repository.
output "chart_repository_url" {
  value       = module.chart_registry.repository_urls["charts/qnsc-service"]
  description = "OCI repository holding the qnsc-service Helm chart."
}

output "chart_repository_arn" {
  value       = module.chart_registry.repository_arns["charts/qnsc-service"]
  description = "ARN of the chart repository — what a pull policy scopes to."
}
