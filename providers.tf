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

provider "tfe" {
  # Token is supplied via the TFE_TOKEN env variable set on this workspace.
  # An organisation-level token is required so this workspace can write
  # variables into the workload workspaces it manages.
}
