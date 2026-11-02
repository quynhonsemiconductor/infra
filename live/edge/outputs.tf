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
  # Still the real ARN: runtime-dev/runtime-prod read it through
  # terraform_remote_state and set it on the ALB HTTPS listener, so a null here
  # would remove the listener certificate on their next apply (runtime-prod is
  # the soak rollback path). Looked up, not managed. Delete this output, the
  # data source and the provider with those stacks.
  value       = data.aws_acm_certificate.wildcard.arn
  description = "ARN of the shared *.qnsc.vn ACM certificate (ap-southeast-1), read by runtime-dev/runtime-prod. No longer managed by this stack."
}

output "landing_pages_subdomain" {
  value       = cloudflare_pages_project.landing.subdomain
  description = "Cloudflare Pages *.pages.dev hostname for qnsc-landing (e.g. qnsc-landing.pages.dev). The qnsc-landing web-deploy CI pushes built assets here."
}

output "ses_identity_arn" {
  value       = aws_sesv2_email_identity.mail_domain.arn
  description = "SES domain identity for outbound mail (qnsc.vn). Every product's IAM policy constructs this same ARN directly (arn:aws:ses:<region>:<account>:identity/<domain>) rather than reading this output, so a product apply never has to run after this one."
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
