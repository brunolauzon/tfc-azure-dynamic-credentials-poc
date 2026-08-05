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
# Platform UAMIs always land in the subscription set via ARM_SUBSCRIPTION_ID
# on the platform workspace. Each workspace targets its own workload Azure subscription.
# ---------------------------------------------------------------------------

locals {
  workspaces = {
    "azure-rg-toto-dev" = {
      workload_subscription_id = "dc585422-8c5b-4b58-bb0c-62c23ac0c77c"
    }
    "azure-rg-tata-dev" = {
      workload_subscription_id = "dc585422-8c5b-4b58-bb0c-62c23ac0c77c"
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

  uami_location = var.uami_location
  tags          = var.tags

  workload_subscription_id = each.value.workload_subscription_id
  workload_rg_location     = try(each.value.workload_rg_location, null)
  role                     = try(each.value.role, "Contributor")

  create_tfc_workspace_variables = true
}
