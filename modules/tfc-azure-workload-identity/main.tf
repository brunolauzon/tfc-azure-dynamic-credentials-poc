locals {
  project_slug = lower(replace(var.tfc_project_name, " ", "-"))
  uami_name    = "uami-tfc-${lower(var.tfc_org_name)}-${local.project_slug}-${var.tfc_workspace_name}"

  tfc_issuer   = "https://app.terraform.io"
  tfc_audience = "api://AzureADTokenExchange"

  run_phases = toset(["plan", "apply"])

  workload_rg_location = coalesce(var.workload_rg_location, var.uami_location)

  tfc_env_vars = var.create_tfc_workspace_variables ? {
    TFC_AZURE_RUN_CLIENT_ID = {
      value       = azurerm_user_assigned_identity.this.client_id
      description = "UAMI client ID for HCP Terraform dynamic credentials — managed by Terraform, do not edit manually."
    }
    ARM_SUBSCRIPTION_ID = {
      value       = var.workload_subscription_id
      description = "Workload subscription ID for HCP Terraform dynamic credentials — managed by Terraform, do not edit manually."
    }
  } : {}
}

# ---------------------------------------------------------------------------
# Platform subscription — UAMI + federated credentials (azurerm)
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "this" {
  name                = local.uami_name
  resource_group_name = var.platform_resource_group
  location            = var.uami_location
  tags                = var.tags

  # Federated credential names are "${uami_name}-{phase}" and Azure caps them at 120 chars.
  lifecycle {
    precondition {
      condition     = length(local.uami_name) <= 114
      error_message = "Derived UAMI name '${local.uami_name}' is too long (max 114 chars so federated credential names stay within Azure's 120-char limit)."
    }
  }
}

resource "azurerm_federated_identity_credential" "this" {
  for_each = local.run_phases

  name                      = "${local.uami_name}-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.this.id
  issuer                    = local.tfc_issuer
  subject                   = "organization:${var.tfc_org_name}:project:${var.tfc_project_name}:workspace:${var.tfc_workspace_name}:run_phase:${each.key}"
  audience                  = [local.tfc_audience]
}

# ---------------------------------------------------------------------------
# Workload subscription — RG + role assignment
#
# AzAPI is used for the RG so each module instance can target a different
# subscription via parent_id. Terraform cannot dynamically select an azurerm
# provider alias inside for_each.
#
# Role assignment stays on azurerm; scope is a full ARM ID so it works
# cross-subscription when the platform identity has rights on that sub.
# ---------------------------------------------------------------------------

resource "azapi_resource" "workload_rg" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  parent_id = "/subscriptions/${var.workload_subscription_id}"
  name      = var.workload_resource_group
  location  = local.workload_rg_location
  tags      = var.tags

  body = {
    properties = {}
  }
}

resource "azurerm_role_assignment" "workload" {
  scope                = azapi_resource.workload_rg.id
  role_definition_name = var.role
  principal_id         = azurerm_user_assigned_identity.this.principal_id

  # Newly created UAMIs are not immediately visible in AAD; skip the check to avoid race failures.
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# Optional HCP Terraform workspace env vars
# ---------------------------------------------------------------------------

data "tfe_workspace" "this" {
  count        = var.create_tfc_workspace_variables ? 1 : 0
  name         = var.tfc_workspace_name
  organization = var.tfc_org_name
}

resource "tfe_variable" "this" {
  for_each = local.tfc_env_vars

  workspace_id = data.tfe_workspace.this[0].id
  key          = each.key
  value        = each.value.value
  category     = "env"
  description  = each.value.description
  sensitive    = false
}
