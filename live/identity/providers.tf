# Auth is inherited from the environment — never a client secret, never a
# hardcoded OIDC switch:
#   CI:        the workflow exports ARM_USE_OIDC=true (GitHub OIDC via the
#              "QNSC CI Infra" / "QNSC CI Infra Read" apps, §7.4).
#   Operators: `az login --tenant <tenant-domain>` first; both providers pick
#              up the Azure CLI session.
provider "azurerm" {
  features {}
  # Key Vault secrets are NEVER read by this stack (values never in state, §7);
  # the CI read identity holds Key Vault READER — metadata only.
}

provider "azuread" {}
