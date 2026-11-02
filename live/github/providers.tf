# The token comes in through the environment (TF_VAR_github_token), never argv
# and never Git. Plans use a READ-ONLY fine-grained token, applies the write one
# (environment `production` only); see README.md for the exact permissions.
provider "github" {
  owner = var.github_owner
  token = var.github_token != "" ? var.github_token : null
}

variable "github_owner" {
  description = "GitHub organisation that owns every repository in this stack."
  type        = string
  default     = "quynhonsemiconductor"
}

variable "github_token" {
  description = "Fine-grained token: read-only for plans/drift, write for apply (CI maps it per job). Empty falls back to GITHUB_TOKEN in the environment."
  type        = string
  default     = ""
  sensitive   = true
}
