variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID that owns the Tunnels."
}

variable "cloudflare_api_token" {
  type        = string
  default     = ""
  description = "cf-ci-infra or an operator token with Cloudflare Tunnel edit on the account. Empty skips provider auth (plan-only bootstrapping)."
  sensitive   = true
}

variable "admin_private_cidr" {
  type        = string
  description = "The office LAN range the qnsc-admin tunnel may route to (door 2). Set in tfvars, never committed with a real value if it is sensitive; the default here is a placeholder."
}

variable "admin_pve_hostname" {
  type        = string
  description = "Door-2 Proxmox hostname. GitHub Actions repository variable TF_VAR_admin_pve_hostname (same source as live/edge's admin_hostnames); real value in product-docs runbook §12.1."
}

variable "admin_pbs_hostname" {
  type        = string
  description = "Door-2 PBS hostname. GitHub Actions repository variable TF_VAR_admin_pbs_hostname."
}
