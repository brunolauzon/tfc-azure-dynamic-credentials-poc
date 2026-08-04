terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.63"
    }
  }

  cloud {
    organization = "brunolauzon-hcp"
    workspaces {
      name = "azure-workload-identity"
    }
  }
}
