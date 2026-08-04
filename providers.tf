provider "azurerm" {
  features {}
  subscription_id                 = var.platform_subscription_id
  use_oidc                        = true
  resource_provider_registrations = "none"
}

provider "azurerm" {
  alias = "workload"
  features {}
  subscription_id                 = var.workload_subscription_id
  use_oidc                        = true
  resource_provider_registrations = "none"
}

provider "tfe" {}
