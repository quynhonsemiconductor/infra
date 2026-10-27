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
    TF_VAR_admin_hostnames (repo variable, JSON object, e.g. {"pve": "<hostname>", "pbs": "<hostname>"}).
    Labels are load-bearing: they are state addresses, so never rename one without a `tofu state mv`.
  EOT
}

variable "cutover_hosts" {
  type        = list(string)
  sensitive   = true # public repo: real values (product-docs runbook §12.1) leak in plan text / PR comments otherwise
  description = "App hosts whose DNS + Workers routes are LIVE. One host is added per product move PR apply; [] until then (rova prod stays on AWS). TF_VAR_cutover_hosts."
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

