provider "azurerm" {
  features {}
  use_oidc = true
  # Key Vault secrets are NEVER read by this stack (values never in state, §7);
  # the CI read identity holds Key Vault READER — metadata only.
}

provider "azuread" {
  use_oidc = true
}
