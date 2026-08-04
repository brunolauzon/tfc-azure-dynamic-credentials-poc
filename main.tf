# ---------------------------------------------------------------------------
# Add one entry per TFC workspace. The map key IS the tfc_workspace_name and
# drives the UAMI name, federated credential subjects, and TFC env variables.
#
# Naming convention: azure-rg-{workload}-{env}
# ---------------------------------------------------------------------------

locals {
  tfc_org_name     = "brunolauzon-hcp"
  tfc_project_name = "Default Project"

  workspaces = {
    "azure-rg-bleep-dev" = {
      workload_subscription_id = "e21b59f3-d80c-435e-a2e3-0b7a77770e38"
      workload_resource_group  = "rg-bleep-dev"
      role                     = "Contributor"
    }
    "azure-rg-bloop-dev" = {
      workload_subscription_id = "e21b59f3-d80c-435e-a2e3-0b7a77770e38"
      workload_resource_group  = "rg-bloop-dev"
      role                     = "Contributor"
    }
  }
}



module "tfc_wi" {
  source   = "./modules/tfc-azure-workload-identity"
  for_each = local.workspaces

  tfc_org_name       = local.tfc_org_name
  tfc_project_name   = local.tfc_project_name
  tfc_workspace_name = each.key

  platform_resource_group = "rg-terraform-identities"
  uami_location           = var.uami_location

  workload_subscription_id = each.value.workload_subscription_id
  workload_resource_group  = each.value.workload_resource_group
  role                     = each.value.role

  create_tfc_workspace_variables = true
  
}
