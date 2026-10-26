variable "location" {
  type        = string
  default     = "southeastasia"
  description = "Azure region — same geography as the server (ap-southeast-1 in AWS terms)."
}

variable "subscription_id" {
  type        = string
  description = "The pay-as-you-go subscription created in pre-work (e)."
}

variable "budget_period_start" {
  type        = string
  description = "Budget window start, RFC3339, e.g. 2026-10-01T00:00:00Z — the first day of the month the subscription was created."

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.budget_period_start))
    error_message = "budget_period_start must be RFC3339 UTC, e.g. 2026-10-01T00:00:00Z (azurerm 5.x rejects a bare date)."
  }
}

variable "budget_period_end" {
  type        = string
  description = "Budget window end, RFC3339, e.g. 2028-09-30T00:00:00Z — the hand-created budget reads 2028-09-30; keep both ends in sync with Azure."

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.budget_period_end))
    error_message = "budget_period_end must be RFC3339 UTC, e.g. 2028-09-30T00:00:00Z (azurerm 5.x rejects a bare date)."
  }
}

variable "office_ip" {
  type        = string
  default     = ""
  description = "Office static IP (public, /32). Empty = allowlists disabled. TF_VAR_office_ip (repo variable), never committed."

  validation {
    condition     = var.office_ip == "" || can(regex("^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}$", var.office_ip))
    error_message = "office_ip must be a dotted IPv4 address (no IPv6, no CIDR suffix), or empty."
  }
}
