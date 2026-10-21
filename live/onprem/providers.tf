provider "azurerm" {
  features {}
  use_oidc = true
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}
