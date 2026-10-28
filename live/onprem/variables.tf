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
  description = "The office LAN range the qnsc-admin tunnel may route to (door 2). GitHub Actions repo SECRET ADMIN_PRIVATE_CIDR (secrets, not variables: variable values print unmasked in step env logs of this public repo)."
  validation {
    condition     = can(cidrnetmask(var.admin_private_cidr))
    error_message = "admin_private_cidr must be a CIDR (e.g. 192.0.2.0/24 — RFC 5737 documentation range)."
  }
}

variable "admin_pve_hostname" {
  type        = string
  sensitive   = true
  description = "Door-2 Proxmox hostname. GitHub Actions repo SECRET ADMIN_PVE_HOSTNAME (same class as live/edge's admin_hostnames; never literal in this public repo). Real value in product-docs runbook §12.1."
  validation {
    condition     = length(var.admin_pve_hostname) > 0
    error_message = "admin_pve_hostname must not be empty."
  }
}

variable "admin_pbs_hostname" {
  type        = string
  sensitive   = true
  description = "Door-2 PBS hostname. GitHub Actions repo SECRET ADMIN_PBS_HOSTNAME."
  validation {
    condition     = length(var.admin_pbs_hostname) > 0
    error_message = "admin_pbs_hostname must not be empty."
  }
}
