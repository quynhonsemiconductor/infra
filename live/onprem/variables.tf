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

variable "admin_private_ip" {
  type        = string
  description = "pve01's address inside admin_private_cidr, the target of the qnsc-admin tunnel route."
}
