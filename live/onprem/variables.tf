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
  sensitive   = true
  description = "The office LAN range the qnsc-admin tunnel may route to (door 2). CI repo variable ADMIN_PRIVATE_CIDR; never committed with a real value."
  validation {
    condition     = can(cidrnetmask(var.admin_private_cidr))
    error_message = "admin_private_cidr must be a CIDR (e.g. 10.0.0.0/24)."
  }
}

variable "admin_pve_hostname" {
  type        = string
  description = "Door-2 Proxmox hostname. GitHub Actions repository variable TF_VAR_admin_pve_hostname (same source as live/edge's admin_hostnames); real value in product-docs runbook §12.1."
}

variable "admin_pbs_hostname" {
  type        = string
  description = "Door-2 PBS hostname. GitHub Actions repository variable TF_VAR_admin_pbs_hostname."
}
