terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.119"
    }
  }

  # Same off-box state account as every other stack (§11.3). Owner-applied
  # only: CI has no Proxmox API token and never will (the endpoint is the
  # admin door, and a token that can create VMs does not belong in Actions).
  backend "azurerm" {
    use_azuread_auth     = true
    resource_group_name  = "rg-qnsc-platform"
    storage_account_name = "stqnsctfstate"
    container_name       = "tfstate"
    key                  = "infra/onprem-vm/terraform.tfstate"
  }
}
