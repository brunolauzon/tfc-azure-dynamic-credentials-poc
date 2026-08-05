# Preserve existing state after consolidating duplicated resources into for_each.

moved {
  from = azurerm_federated_identity_credential.plan
  to   = azurerm_federated_identity_credential.this["plan"]
}

moved {
  from = azurerm_federated_identity_credential.apply
  to   = azurerm_federated_identity_credential.this["apply"]
}

moved {
  from = tfe_variable.run_client_id[0]
  to   = tfe_variable.this["TFC_AZURE_RUN_CLIENT_ID"]
}

moved {
  from = tfe_variable.subscription_id[0]
  to   = tfe_variable.this["ARM_SUBSCRIPTION_ID"]
}

# Workload RGs moved from azurerm (single-sub provider alias) to azapi
# (per-workspace subscription via parent_id). Different resource types cannot
# use moved{}; remove the old address from state and import into azapi:
#
#   terraform state rm \
#     'module.tfc_wi["<workspace>"].azurerm_resource_group.workload'
#   terraform import \
#     'module.tfc_wi["<workspace>"].azapi_resource.workload_rg' \
#     '/subscriptions/<workload-sub>/resourceGroups/<rg-name>'
