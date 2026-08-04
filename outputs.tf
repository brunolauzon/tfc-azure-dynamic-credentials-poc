output "workload_identities" {
  description = "UAMI names and client IDs for all provisioned workspaces."
  value = {
    for k, m in module.tfc_wi : k => {
      uami_name      = m.uami_name
      uami_client_id = m.uami_client_id
    }
  }
}
