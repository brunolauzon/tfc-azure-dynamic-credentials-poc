terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  cloud {
    organization = "<your-hcp-org>"
    workspaces {
      name = "<your-workspace>"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_subscription" "current" {}

output "subscription_display_name" {
  value = data.azurerm_subscription.current.display_name
}

output "subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
}