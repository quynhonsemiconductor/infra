terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10"
    }
  }

  # State lives OFF the box it manages (§11.3): Azure Blob, OIDC, blob-lease
  # locking, versioning + soft delete on the account. stqnsctfstate is created
  # once BY HAND (pre-work (e)) and then imported into live/identity.
  backend "azurerm" {
    resource_group_name  = "rg-qnsc-platform"
    storage_account_name = "stqnsctfstate"
    container_name       = "tfstate"
    key                  = "infra/onprem/terraform.tfstate"
    use_oidc             = true
    use_azuread_auth     = true
  }
}

# Values are never in state and never in Git (§7): the Cloudflare token comes
# in through the environment (TF_VAR_cloudflare_api_token), never argv.
