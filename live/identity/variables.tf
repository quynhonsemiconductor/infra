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
