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
  description = "Budget window start, YYYY-MM-DD — the first day of the month the subscription was created."
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
