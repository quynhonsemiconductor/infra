# On-prem edge variables — NO defaults: tofu plan/apply get them from
# TF_VAR_* environment entries wired to GitHub Actions repository variables
# and secrets in .github/workflows/infra-plan.yml + infra-apply.yml. Real
# hostname values are recorded in product-docs (runbook §12.1), never here.

variable "admin_hostnames" {
  type        = map(string)
  sensitive   = true # public repo: real values (product-docs runbook §12.1) leak in plan text / PR comments otherwise
  description = <<-EOT
    Door-2 hostnames (pve/pbs): STATIC LABEL -> hostname map. Labels are the only part that appears in
    resource addresses; the values stay sensitive end to end (tofu forbids iterating a sensitive value,
    so for_each runs over the labels and the hostname lands in sensitive attributes only).
    TF_VAR_admin_hostnames (repo SECRET — vars print in logs, secrets are masked; JSON object,
    e.g. {"pve": "<hostname>", "pbs": "<hostname>"}).
    Labels are load-bearing: they are state addresses, so never rename one without a `tofu state mv`.
    ONE source: live/onprem reads the SAME secret (its old ADMIN_PVE_HOSTNAME / ADMIN_PBS_HOSTNAME are retired).
  EOT

  validation {
    condition     = toset(keys(var.admin_hostnames)) == toset(["pve", "pbs"])
    error_message = "admin_hostnames must have exactly the keys pve and pbs (the labels are state addresses)."
  }
  validation {
    condition     = alltrue([for h in values(var.admin_hostnames) : can(regex("^[a-z0-9-]+\\.qnsc\\.vn$", h))])
    error_message = "every admin_hostnames value must be a hostname under qnsc.vn (^[a-z0-9-]+\\.qnsc\\.vn$): a placeholder such as 'hostname PVE' once produced a tunnel that 404'd for 3 days."
  }
}

variable "cutover_hosts" {
  type        = list(string)
  sensitive   = true # public repo: real values (product-docs runbook §12.1) leak in plan text / PR comments otherwise
  description = "App hosts whose DNS + Workers routes are LIVE. One host is added per product move PR apply; [] until then (rova prod stays on AWS). TF_VAR_cutover_hosts (repo SECRET — vars print in logs, secrets are masked; JSON list)."
}

variable "tunnels_exist" {
  type        = bool
  description = "False until live/onprem has created the qnsc-apps/qnsc-admin tunnels; gates the data sources and DNS. TF_VAR_tunnels_exist."
}

variable "grp_platform_admins_id" {
  type        = string
  description = "Entra object id of grp-qnsc-platform-admins. TF_VAR_grp_platform_admins_id (repo variable)."
}

variable "grp_developers_id" {
  type        = string
  description = "Entra object id of grp-qnsc-developers. TF_VAR_grp_developers_id (repo variable)."
}

variable "entra_tenant_id" {
  type        = string
  description = "Entra tenant id (not a secret; CI-fed for one source of truth). TF_VAR_entra_tenant_id."
}

variable "entra_idp_client_id" {
  type        = string
  description = "Client id of the Zero Trust Entra IdP app registration. TF_VAR_entra_idp_client_id."
}

variable "entra_idp_client_secret" {
  type        = string
  sensitive   = true
  description = "Client secret of the Zero Trust Entra IdP app — created out-of-band (owner, stdin); lands in the CF state as THE documented exception (plan §7). TF_VAR_entra_idp_client_secret (repo secret)."
}


variable "admin_private_cidr" {
  type        = string
  sensitive   = true # public repo: the real range lives in product-docs (runbook §12.1)
  description = <<-EOT
    The office LAN range the qnsc-admin tunnel routes to (door 2). WARP removes it from the split-tunnel
    Exclude list so admin laptops reach it through Cloudflare. The SAME secret live/onprem reads:
    TF_VAR_admin_private_cidr (repo SECRET ADMIN_PRIVATE_CIDR — secrets, not variables: variable values
    print unmasked in step env logs of this public repo).
    Must be a /8../32 inside RFC 1918 (10/8, 172.16/12, 192.168/16): the exclude-list subtraction in warp.tf
    only carves ranges that sit inside one default exclude entry.
  EOT

  validation {
    condition     = can(cidrnetmask(var.admin_private_cidr))
    error_message = "admin_private_cidr must be an IPv4 CIDR (e.g. 192.0.2.0/24 — RFC 5737 documentation range)."
  }
  validation {
    condition = can(cidrnetmask(var.admin_private_cidr)) && anytrue([
      for r in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] :
      cidrcontains(r, var.admin_private_cidr)
    ])
    error_message = "admin_private_cidr must sit inside RFC 1918 (10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16). A placeholder or a public range would leave WARP routing nothing to the office."
  }
}
