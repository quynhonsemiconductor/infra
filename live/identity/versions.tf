terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-qnsc-platform"
    storage_account_name = "stqnsctfstate"
    container_name       = "tfstate"
    key                  = "infra/identity/terraform.tfstate"
    use_oidc             = true
    use_azuread_auth     = true
  }
}

# Auth everywhere is GitHub OIDC in CI ("QNSC CI Infra" / "QNSC CI Infra Read",
# §7.4) and az login --use-oidc for operators. No client secrets anywhere.
