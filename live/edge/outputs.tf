output "ratelimit_ruleset_id" {
  value       = module.edge.ratelimit_ruleset_id
  description = "ID of the rate-limiting ruleset."
}

output "managed_ruleset_id" {
  value       = module.edge.managed_ruleset_id
  description = "ID of the managed-WAF ruleset (null when disabled)."
}

output "custom_ruleset_id" {
  value       = module.edge.custom_ruleset_id
  description = "ID of the custom-firewall ruleset (null when none)."
}

output "acm_cert_arn" {
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
  description = "Validated wildcard *.qnsc.vn ACM cert ARN (ap-southeast-1) for the shared ALB. Consumed by runtime-dev/runtime-prod via terraform_remote_state."
}

output "landing_pages_subdomain" {
  value       = cloudflare_pages_project.landing.subdomain
  description = "Cloudflare Pages *.pages.dev hostname for qnsc-landing (e.g. qnsc-landing.pages.dev). The qnsc-landing web-deploy CI pushes built assets here."
}

output "landing_turnstile_sitekey" {
  value       = module.landing_turnstile.sitekey
  description = "Public Turnstile sitekey for the qnsc-landing contact form — bake into the client (non-secret)."
}

output "landing_turnstile_secret" {
  value       = module.landing_turnstile.secret
  sensitive   = true
  description = "Turnstile secret — set out-of-band as the Pages TURNSTILE_SECRET env var (tofu output -raw landing_turnstile_secret). Do not commit."
}
