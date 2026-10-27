terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
  }

  # State lives OFF the box it manages (§11.3): Azure Blob, OIDC, blob-lease
  # locking, versioning + soft delete on the account. stqnsctfstate is created
  # once BY HAND (pre-work (e)) and then imported into live/identity.
  # Auth method comes from the CI identity's environment (ARM_USE_OIDC=true +
  # ARM_CLIENT_ID/ARM_TENANT_ID); owner-side runs export the same.
  # use_azuread_auth stays ON here: it is the data-plane access choice —
  # without it tofu 1.9.1 falls back to account ListKeys, which the Read
  # identity cannot do.
  backend "azurerm" {
    use_azuread_auth     = true
    resource_group_name  = "rg-qnsc-platform"
    storage_account_name = "stqnsctfstate"
    container_name       = "tfstate"
    key                  = "infra/onprem/terraform.tfstate"
  }
}

# Values are never in state and never in Git (§7): the Cloudflare token comes
# in through the environment (TF_VAR_cloudflare_api_token), never argv.
