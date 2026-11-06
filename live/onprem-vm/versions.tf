terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Exact pin: 0.120.0 is the version whose `proxmox_storage_pbs` schema was read when the encryption
      # precondition was written (encryption_key_fingerprint read-only; encryption_key sensitive but NOT
      # write-only — `tofu providers schema -json`). A Renovate bump re-reads that before it lands.
      version = "0.120.0"
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
