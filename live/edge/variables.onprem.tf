# On-prem edge variables — fed by GitHub Actions repository variables; real
# values recorded in product-docs (§7.6), never in this public repo.

variable "admin_hostnames" {
  type        = list(string)
  description = "Door-2 hostnames (pve/pbs). GitHub Actions repository variable TF_VAR_admin_hostnames."
}

variable "grp_platform_admins_id" {
  type        = string
  description = "Entra object id of grp-qnsc-platform-admins."
}

variable "grp_developers_id" {
  type        = string
  description = "Entra object id of grp-qnsc-developers."
}

variable "entra_tenant_id" {
  type        = string
  description = "Entra tenant id (not a secret; still CI-fed for one source of truth)."
}

variable "entra_idp_client_id" {
  type        = string
  description = "Client id of the Zero Trust Entra IdP app registration."
}

variable "entra_idp_client_secret" {
  type        = string
  sensitive   = true
  description = "Client secret of the Zero Trust Entra IdP app — created out-of-band (owner, stdin), CI-fed."
}
