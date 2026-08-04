variable "tfc_org_name" {
  description = "HCP Terraform organisation name (case-sensitive)."
  type        = string
  default     = "brunolauzon-hcp"
}

variable "tfc_project_name" {
  description = "HCP Terraform project name (case-sensitive)."
  type        = string
  default     = "Default Project"
}

variable "platform_subscription_id" {
  description = "Single Azure subscription where the platform resource group and all UAMIs live."
  type        = string
  default     = "bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe"
}

variable "platform_resource_group" {
  description = "Centralised platform resource group that owns all UAMIs."
  type        = string
  default     = "rg-terraform-identities"
}

variable "uami_location" {
  description = "Azure region for all UAMIs (and workload RGs unless overridden per workspace)."
  type        = string
  default     = "canadacentral"
}

variable "tags" {
  description = "Tags applied to all UAMIs and workload resource groups."
  type        = map(string)
  default = {
    managed-by = "terraform"
    purpose    = "tfc-workload-identity"
  }
}
