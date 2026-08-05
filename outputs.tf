output "workload_identities" {
  description = "UAMI and workload details for all provisioned workspaces."
  value = {
    for k, m in module.tfc_wi : k => {
      uami_name                    = m.uami_name
      uami_client_id               = m.uami_client_id
      uami_principal_id            = m.uami_principal_id
      workload_subscription_id     = m.workload_subscription_id
      workload_resource_group_name = m.workload_resource_group_name
      workload_resource_group_id   = m.workload_resource_group_id
    }
  }
}
