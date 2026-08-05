output "uami_name" {
  description = "Name of the User-Assigned Managed Identity created in the platform resource group."
  value       = azurerm_user_assigned_identity.this.name
}

output "uami_client_id" {
  description = "Client ID of the UAMI — set this as TFC_AZURE_RUN_CLIENT_ID in the HCP Terraform workspace."
  value       = azurerm_user_assigned_identity.this.client_id
}

output "uami_principal_id" {
  description = "Object / principal ID of the UAMI."
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "uami_id" {
  description = "Full Azure resource ID of the UAMI."
  value       = azurerm_user_assigned_identity.this.id
}

output "federated_credential_ids" {
  description = "Map of run phase → federated identity credential resource ID."
  value       = { for phase, cred in azurerm_federated_identity_credential.this : phase => cred.id }
}

output "workload_resource_group_name" {
  description = "Workload resource group name derived from the workspace (azure-rg-X-Y → rg-X-Y)."
  value       = local.workload_resource_group
}

output "workload_resource_group_id" {
  description = "Resource ID of the workload resource group."
  value       = azapi_resource.workload_rg.id
}

output "workload_subscription_id" {
  description = "Azure subscription ID where the workload resource group lives."
  value       = var.workload_subscription_id
}

output "role_assignment_id" {
  description = "Resource ID of the RBAC role assignment on the workload resource group."
  value       = azurerm_role_assignment.workload.id
}

output "tfc_workspace_variables_summary" {
  description = "Key/value pairs to set as Environment variables in the HCP Terraform workspace (only when create_tfc_workspace_variables = false)."
  value = var.create_tfc_workspace_variables ? null : {
    TFC_AZURE_RUN_CLIENT_ID = azurerm_user_assigned_identity.this.client_id
    ARM_SUBSCRIPTION_ID     = var.workload_subscription_id
  }
}
