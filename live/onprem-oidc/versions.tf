terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
  }

  # Same off-box state account as every other stack (§11.3). Owner-applied
  # only (see README): the JWKS comes from the running cluster, so there is
  # nothing for CI to plan against on a merge.
  backend "azurerm" {
    use_azuread_auth     = true
    resource_group_name  = "rg-qnsc-platform"
    storage_account_name = "stqnsctfstate"
    container_name       = "tfstate"
    key                  = "infra/onprem-oidc/terraform.tfstate"
  }
}
