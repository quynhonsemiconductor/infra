# On-prem edge variables — fed by GitHub Actions repository variables; real
# values recorded in product-docs (§7.6), never in this public repo.

variable "admin_hostnames" {
  # Placeholder default so `tofu plan` runs in CI; the REAL values are set via
  # the GitHub Actions repository variable TF_VAR_admin_hostnames before any
  # apply, and are recorded in product-docs (runbook §12.1) — never here.
  type    = list(string)
  default = ["pve-SET-VIA-CI.example.invalid", "pbs-SET-VIA-CI.example.invalid"]

  validation {
    condition     = alltrue([for h in var.admin_hostnames : can(regex("SET-VIA-CI", h)) || can(regex("\\.example\\.invalid$", h))])
    error_message = "Wire TF_VAR_admin_hostnames before apply."
  }
}

variable "grp_platform_admins_id" {
  type    = string
  default = "00000000-0000-0000-0000-000000000000" # SET VIA CI (repo variable)
}

variable "grp_developers_id" {
  type    = string
  default = "00000000-0000-0000-0000-000000000000" # SET VIA CI
}

variable "entra_tenant_id" {
  type    = string
  default = "00000000-0000-0000-0000-000000000000" # SET VIA CI
}

variable "entra_idp_client_id" {
  type    = string
  default = "00000000-0000-0000-0000-000000000000" # SET VIA CI
}

variable "entra_idp_client_secret" {
  type      = string
  sensitive = true
  default   = "PLACEHOLDER-SET-VIA-CI" # secret: created out-of-band (owner, stdin), fed by a CI secret
}
