# ---------------------------------------------------------------------------
# Add one entry per TFC workspace. The map key IS the tfc_workspace_name and
# drives the UAMI name, federated credential subjects, workload RG name, and
# TFC env variables.
#
# Naming convention: azure-rg-{workload}-{env}
#   → workload RG:   rg-{workload}-{env}
#
# Required key:   workload_subscription_id
# Optional keys:  role, workload_rg_location
#   (if you set an optional key on one entry, set it on all entries —
#    or leave them out entirely and rely on the defaults below)
#
# Platform UAMIs always land in var.platform_subscription_id.
# Each workspace targets its own workload Azure subscription.
# ---------------------------------------------------------------------------

locals {
  workspaces = {
    "azure-rg-bleep-dev" = {
      workload_subscription_id = "e21b59f3-d80c-435e-a2e3-0b7a77770e38"
    }
    "azure-rg-bloop-dev" = {
      workload_subscription_id = "e21b59f3-d80c-435e-a2e3-0b7a77770e38"
    }
  }
}

module "tfc_wi" {
  source   = "./modules/tfc-azure-workload-identity"
  for_each = local.workspaces

  providers = {
    azurerm = azurerm
    azapi   = azapi
    tfe     = tfe
  }

  tfc_org_name       = var.tfc_org_name
  tfc_project_name   = var.tfc_project_name
  tfc_workspace_name = each.key

  platform_resource_group = var.platform_resource_group
  uami_location           = var.uami_location
  tags                    = var.tags

  workload_subscription_id = each.value.workload_subscription_id
  workload_rg_location     = try(each.value.workload_rg_location, null)
  role                     = try(each.value.role, "Contributor")

  create_tfc_workspace_variables = true
}
