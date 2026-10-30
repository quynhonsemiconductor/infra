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
    error_message = "admin_private_cidr must be an IPv4 CIDR (e.g. 192.0.2.0/24 — RFC 5737 documentation range)."
  }
  validation {
    condition = can(cidrnetmask(var.admin_private_cidr)) && anytrue([
      for r in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] : cidrcontains(r, var.admin_private_cidr)
    ])
    error_message = "admin_private_cidr must sit inside RFC 1918 (10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16)."
  }
}

variable "admin_hostnames" {
  type        = map(string)
  sensitive   = true # public repo: real values (product-docs runbook §12.1) leak in plan text / PR comments otherwise
  description = <<-EOT
    Door-2 hostnames: STATIC LABEL -> hostname map ({"pve": "<hostname>", "pbs": "<hostname>"}). ONE source:
    the SAME GitHub Actions repo SECRET ADMIN_HOSTNAMES that live/edge reads (TF_VAR_admin_hostnames; secrets
    are masked, variables print). Never literal in this public repo; real values in product-docs runbook §12.1.
  EOT

  validation {
    condition     = toset(keys(var.admin_hostnames)) == toset(["pve", "pbs"])
    error_message = "admin_hostnames must have exactly the keys pve and pbs."
  }
  validation {
    condition     = alltrue([for h in values(var.admin_hostnames) : can(regex("^[a-z0-9-]+\\.qnsc\\.vn$", h))])
    error_message = "every admin_hostnames value must be a hostname under qnsc.vn (^[a-z0-9-]+\\.qnsc\\.vn$): a placeholder such as 'hostname PVE' once produced a tunnel that 404'd for 3 days."
  }
}
