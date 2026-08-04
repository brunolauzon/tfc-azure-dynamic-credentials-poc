locals {
  project_slug = lower(replace(var.tfc_project_name, " ", "-"))

  uami_name = "uami-tfc-${lower(var.tfc_org_name)}-${local.project_slug}-${var.tfc_workspace_name}"

  fed_cred_plan_name  = "${local.uami_name}-plan"
  fed_cred_apply_name = "${local.uami_name}-apply"

  tfc_issuer   = "https://app.terraform.io"
  tfc_audience = "api://AzureADTokenExchange"

  subject_plan  = "organization:${var.tfc_org_name}:project:${var.tfc_project_name}:workspace:${var.tfc_workspace_name}:run_phase:plan"
  subject_apply = "organization:${var.tfc_org_name}:project:${var.tfc_project_name}:workspace:${var.tfc_workspace_name}:run_phase:apply"

  workload_rg_id = "/subscriptions/${var.workload_subscription_id}/resourceGroups/${var.workload_resource_group}"
}

data "azurerm_resource_group" "platform" {
  name = var.platform_resource_group
}

resource "azurerm_user_assigned_identity" "this" {
  name                = local.uami_name
  resource_group_name = data.azurerm_resource_group.platform.name
  location            = var.uami_location
}

# Federated Identity Credentials — one per run phase

resource "azurerm_federated_identity_credential" "plan" {
  name                      = local.fed_cred_plan_name
  user_assigned_identity_id = azurerm_user_assigned_identity.this.id
  issuer                    = local.tfc_issuer
  subject                   = local.subject_plan
  audience                  = [local.tfc_audience]
}

resource "azurerm_federated_identity_credential" "apply" {
  name                      = local.fed_cred_apply_name
  user_assigned_identity_id = azurerm_user_assigned_identity.this.id
  issuer                    = local.tfc_issuer
  subject                   = local.subject_apply
  audience                  = [local.tfc_audience]
}

# Role assignment — cross-subscription, scoped to workload resource group

resource "azurerm_role_assignment" "workload" {
  scope                = local.workload_rg_id
  role_definition_name = var.role
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

data "tfe_workspace" "this" {
  count        = var.create_tfc_workspace_variables ? 1 : 0
  name         = var.tfc_workspace_name
  organization = var.tfc_org_name
}

resource "tfe_variable" "run_client_id" {
  count        = var.create_tfc_workspace_variables ? 1 : 0
  workspace_id = data.tfe_workspace.this[0].id
  key          = "TFC_AZURE_RUN_CLIENT_ID"
  value        = azurerm_user_assigned_identity.this.client_id
  category     = "env"
  description  = "UAMI client ID for HCP Terraform dynamic credentials — managed by Terraform, do not edit manually."
  sensitive    = false
}

resource "tfe_variable" "subscription_id" {
  count        = var.create_tfc_workspace_variables ? 1 : 0
  workspace_id = data.tfe_workspace.this[0].id
  key          = "ARM_SUBSCRIPTION_ID"
  value        = var.workload_subscription_id
  category     = "env"
  description  = "Workload subscription ID for HCP Terraform dynamic credentials — managed by Terraform, do not edit manually."
  sensitive    = false
}
