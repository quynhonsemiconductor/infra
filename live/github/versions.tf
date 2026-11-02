terraform {
  required_version = ">= 1.9"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # State off the box, like every other stack: Azure Blob, OIDC, blob-lease
  # locking (stqnsctfstate). The state holds NO secret values: this stack never
  # manages a secret (see README.md).
  backend "azurerm" {
    use_azuread_auth     = true
    resource_group_name  = "rg-qnsc-platform"
    storage_account_name = "stqnsctfstate"
    container_name       = "tfstate"
    key                  = "infra/github/terraform.tfstate"
  }
}
