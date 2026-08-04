provider "azurerm" {
  features {}
  subscription_id                 = var.platform_subscription_id
  use_oidc                        = true
  resource_provider_registrations = "none"
}

# AzAPI uses the same OIDC credentials as azurerm. It is not pinned to a
# subscription — each module instance sets the workload subscription via
# parent_id so workspaces can target different Azure subscriptions.
provider "azapi" {
  use_oidc = true
}

provider "tfe" {
  # Token is supplied via the TFE_TOKEN env variable set on this workspace.
  # An organisation-level token is required so this workspace can write
  # variables into the workload workspaces it manages.
}
