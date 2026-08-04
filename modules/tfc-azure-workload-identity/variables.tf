variable "tfc_org_name" {
  description = "HCP Terraform organisation name (case-sensitive)."
  type        = string
}

variable "tfc_project_name" {
  description = "HCP Terraform project name (case-sensitive). Defaults to 'Default Project'."
  type        = string
  default     = "Default Project"
}

variable "tfc_workspace_name" {
  description = <<-EOT
    HCP Terraform workspace name following the convention azure-rg-{workload}-{env}.
    This value drives the UAMI name and both federated credential subjects.
  EOT
  type        = string

  validation {
    condition     = can(regex("^azure-rg-[a-z0-9]+-[a-z0-9]+$", var.tfc_workspace_name))
    error_message = "tfc_workspace_name must follow the pattern azure-rg-{workload}-{env} (lowercase alphanumeric segments only)."
  }
}

variable "platform_resource_group" {
  description = "Name of the centralised platform resource group that owns all UAMIs (e.g. rg-terraform-identities)."
  type        = string
  default     = "rg-terraform-identities"
}

variable "uami_location" {
  description = "Azure region for the User-Assigned Managed Identity."
  type        = string
}

variable "workload_subscription_id" {
  description = "Azure subscription ID for this workspace's workload resource group and role assignment. May differ per workspace."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.workload_subscription_id))
    error_message = "workload_subscription_id must be a valid UUID."
  }
}

variable "workload_resource_group" {
  description = "Name of the workload resource group to create and grant the UAMI access to (e.g. rg-fibre-dev)."
  type        = string

  validation {
    condition     = can(regex("^rg-[a-z0-9]+-[a-z0-9]+$", var.workload_resource_group))
    error_message = "workload_resource_group must follow the pattern rg-{workload}-{env} (lowercase alphanumeric segments only)."
  }
}

variable "workload_rg_location" {
  description = "Azure region for the workload resource group. Defaults to the UAMI location when null."
  type        = string
  default     = null
}

variable "role" {
  description = "RBAC role to assign to the UAMI on the workload resource group."
  type        = string
  default     = "Contributor"

  validation {
    condition     = contains(["Contributor", "Reader", "Owner", "Storage Blob Data Contributor"], var.role)
    error_message = "role must be one of: Contributor, Reader, Owner, Storage Blob Data Contributor."
  }
}

variable "create_tfc_workspace_variables" {
  description = "When true, the module creates TFC_AZURE_RUN_CLIENT_ID and ARM_SUBSCRIPTION_ID workspace variables in HCP Terraform."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the UAMI and workload resource group."
  type        = map(string)
  default     = {}
}
