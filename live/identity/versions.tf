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
    # stqnsctfstate has SHARED KEYS DISABLED (imported in state_backend.tf), so
    # the data plane MUST authenticate with Microsoft Entra — hardcoding this
    # here is correct for both CI (ARM_USE_OIDC=true) and a local `az login`.
    use_azuread_auth = true
  }
}

# Auth everywhere: GitHub OIDC in CI ("QNSC CI Infra" / "QNSC CI Infra Read",
# §7.4) — the workflow exports ARM_USE_OIDC=true and the subscription ID — and
# `az login --tenant <tenant-domain>` for an operator at the laptop. No client
# secrets anywhere.
