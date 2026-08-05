# HCP Terraform → Azure Dynamic Provider Credentials

PoC for [HCP Terraform Dynamic Provider Credentials](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/azure-configuration) with Azure — using a **User-Assigned Managed Identity (UAMI)** and federated identity credentials instead of App Registrations or stored secrets.

**What you get:** short-lived OIDC tokens per run, no `ARM_CLIENT_SECRET`, and one UAMI per HCP Terraform workspace.

---

## Contents

1. [How it works](#how-it-works)
2. [Architecture](#architecture)
3. [Bootstrap (one-time)](#bootstrap-one-time)
4. [Deploy](#deploy)
5. [Adding a workspace](#adding-a-workspace)
6. [Module reference](#module-reference)
7. [Troubleshooting](#troubleshooting)
8. [References](#references)

---

## How it works

```
HCP TF run starts
        │
        ├─ Mints a signed OIDC JWT
        │    subject: organization:<org>:project:<project>:workspace:<ws>:run_phase:<plan|apply>
        │
        ├─ Injects ARM_OIDC_TOKEN into the runner
        │
        └─ AzureRM provider exchanges the JWT for a short-lived Azure access token
               using TFC_AZURE_PROVIDER_AUTH + TFC_AZURE_RUN_CLIENT_ID + ARM_* vars
                    │
                    └─ Azure validates issuer + subject against the workspace's UAMI
```

- No secret is stored. Tokens expire after the run (~15 minutes).
- Subjects are workspace-scoped — one workspace cannot impersonate another's UAMI.

---

## Architecture

**One platform subscription** holds every UAMI. **Each workspace has its own workload Azure subscription** for the resource group and role assignment.

```
Platform subscription  (single)
  └─ rg-terraform-identities
       ├─ uami-tfc-…-workspace-A
       │    ├─ federated cred: run_phase:plan
       │    └─ federated cred: run_phase:apply
       └─ uami-tfc-…-workspace-B
            ├─ federated cred: run_phase:plan
            └─ federated cred: run_phase:apply
                    │
                    │  Role assignment (scoped to that workspace's workload RG)
                    ▼
Workload subscription A          Workload subscription B
  └─ rg-workload-a                 └─ rg-workload-b
       → Contributor for                → Contributor for
         workspace-A UAMI only            workspace-B UAMI only
```

| Provider | Role |
|----------|------|
| `azurerm` | Platform subscription — creates UAMIs and federated credentials |
| `azapi` | Not pinned to a subscription — creates each workload RG via `parent_id = /subscriptions/<workload-sub>/…` |
| `azurerm` (same) | Role assignment using a full ARM scope ID (cross-subscription) |

AzAPI is used for workload RGs because Terraform cannot dynamically select an `azurerm` provider alias inside `for_each`. That lets every workspace map entry specify a different `workload_subscription_id`.

### Naming

| Artifact | Pattern | Example |
|----------|---------|---------|
| TFC workspace | `azure-rg-{workload}-{env}` | `azure-rg-fibre-dev` |
| UAMI | `uami-tfc-{org}-{project}-{workspace}` | `uami-tfc-acme-default-project-azure-rg-fibre-dev` |
| Federated cred | `{uami-name}-{plan\|apply}` | `…-azure-rg-fibre-dev-plan` |
| Workload RG | `rg-{workload}-{env}` | `rg-fibre-dev` |

`tfc_workspace_name` is the single source of truth — UAMI names, OIDC subjects, and the workload RG name (`azure-rg-X-Y` → `rg-X-Y`) are derived from it.

### Layout

```
.
├── main.tf              # workspaces map + module for_each
├── providers.tf         # azurerm (platform), azapi, tfe
├── variables.tf
├── outputs.tf
├── versions.tf          # cloud{} + required_providers
└── modules/tfc-azure-workload-identity/
    ├── main.tf          # UAMI, fed creds, workload RG, role, optional TFC vars
    ├── variables.tf
    ├── outputs.tf
    ├── moved.tf         # state moves for for_each refactors
    └── versions.tf
```

---

## Bootstrap (one-time)

This config runs in the `azure-workload-identity` HCP Terraform workspace. That workspace needs Azure credentials before the first apply — set them up once manually.

### 0. Set variables

Fill these in once, then run the steps below in the **same shell session**:

```bash
# Required — edit these values
PLATFORM_SUB="<platform-subscription-id>"
WORKLOAD_SUB="<workload-subscription-id>"   # re-run step 4 for each extra workload sub
TENANT_ID="<azure-ad-tenant-id>"
TFC_ORG="<hcp-terraform-org-name>"
LOCATION="canadacentral"

# Usually left as-is
PLATFORM_RG="rg-terraform-identities"
PLATFORM_UAMI="uami-tfc-platform"
TFC_PROJECT="Default Project"
TFC_PLATFORM_WS="azure-workload-identity"
```

### 1. Platform resource group

```bash
az group create \
  --name "$PLATFORM_RG" \
  --location "$LOCATION" \
  --subscription "$PLATFORM_SUB"
```

### 2. Platform UAMI

Identity used by the `azure-workload-identity` workspace itself (separate from per-workload UAMIs).

```bash
az identity create \
  --name "$PLATFORM_UAMI" \
  --resource-group "$PLATFORM_RG" \
  --location "$LOCATION" \
  --subscription "$PLATFORM_SUB"

PLATFORM_UAMI_CLIENT_ID=$(az identity show \
  --name "$PLATFORM_UAMI" \
  --resource-group "$PLATFORM_RG" \
  --subscription "$PLATFORM_SUB" \
  --query clientId -o tsv)

PLATFORM_UAMI_OBJECT_ID=$(az identity show \
  --name "$PLATFORM_UAMI" \
  --resource-group "$PLATFORM_RG" \
  --subscription "$PLATFORM_SUB" \
  --query principalId -o tsv)

echo "PLATFORM_UAMI_CLIENT_ID=$PLATFORM_UAMI_CLIENT_ID"
echo "PLATFORM_UAMI_OBJECT_ID=$PLATFORM_UAMI_OBJECT_ID"
```

### 3. Federated credentials (plan + apply)

```bash
az identity federated-credential create \
  --name "tfc-platform-plan" \
  --identity-name "$PLATFORM_UAMI" \
  --resource-group "$PLATFORM_RG" \
  --subscription "$PLATFORM_SUB" \
  --issuer "https://app.terraform.io" \
  --subject "organization:${TFC_ORG}:project:${TFC_PROJECT}:workspace:${TFC_PLATFORM_WS}:run_phase:plan" \
  --audience "api://AzureADTokenExchange"

az identity federated-credential create \
  --name "tfc-platform-apply" \
  --identity-name "$PLATFORM_UAMI" \
  --resource-group "$PLATFORM_RG" \
  --subscription "$PLATFORM_SUB" \
  --issuer "https://app.terraform.io" \
  --subject "organization:${TFC_ORG}:project:${TFC_PROJECT}:workspace:${TFC_PLATFORM_WS}:run_phase:apply" \
  --audience "api://AzureADTokenExchange"
```

### 4. RBAC for the platform UAMI

Grant rights on the **platform** subscription once, then on **every workload subscription** the map will use:

```bash
# Platform subscription — create UAMIs
az role assignment create \
  --assignee "$PLATFORM_UAMI_OBJECT_ID" \
  --role "Contributor" \
  --scope "/subscriptions/${PLATFORM_SUB}"

# Workload subscription — create RGs + role assignments
# For each extra workload sub:
#   WORKLOAD_SUB="<another-workload-subscription-id>"
az role assignment create \
  --assignee "$PLATFORM_UAMI_OBJECT_ID" \
  --role "Contributor" \
  --scope "/subscriptions/${WORKLOAD_SUB}"

az role assignment create \
  --assignee "$PLATFORM_UAMI_OBJECT_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/${WORKLOAD_SUB}"
```

`Contributor` creates resource groups; `User Access Administrator` writes role assignments. Both are required on each workload subscription.

### 5. Platform workspace variables

In HCP Terraform → workspace `azure-workload-identity` → Variables, add these **environment** variables:

| Key | Value | Sensitive |
|-----|-------|-----------|
| `TFC_AZURE_PROVIDER_AUTH` | `true` | No |
| `ARM_TENANT_ID` | `$TENANT_ID` | No |
| `ARM_SUBSCRIPTION_ID` | `$PLATFORM_SUB` | No |
| `TFC_AZURE_RUN_CLIENT_ID` | `$PLATFORM_UAMI_CLIENT_ID` | No |
| `TFE_TOKEN` | Org-level API token | **Yes** |

Print the values to paste into the UI:

```bash
echo "ARM_TENANT_ID=$TENANT_ID"
echo "ARM_SUBSCRIPTION_ID=$PLATFORM_SUB"
echo "TFC_AZURE_RUN_CLIENT_ID=$PLATFORM_UAMI_CLIENT_ID"
```

`TFE_TOKEN` must be an **organisation** token so this workspace can write variables into the workload workspaces it manages. Create one under **Organization Settings → API Tokens**.

`ARM_SUBSCRIPTION_ID` on this platform workspace is the **platform** subscription. Per-workload `ARM_SUBSCRIPTION_ID` values are written automatically into each `azure-rg-*` workspace by the module.

### 6. Shared variable set for workload workspaces

**Settings → Variable Sets → New**:

- Name: `azure-workload-identity`
- Scope: attach to `azure-rg-*` workspaces
- Environment variables:

| Key | Value |
|-----|-------|
| `TFC_AZURE_PROVIDER_AUTH` | `true` |
| `ARM_TENANT_ID` | `$TENANT_ID` |

`TFC_AZURE_RUN_CLIENT_ID` and `ARM_SUBSCRIPTION_ID` are created automatically by the module (`create_tfc_workspace_variables = true`) — each workspace gets its own workload subscription ID.

---

## Deploy

After bootstrap:

```bash
terraform init
terraform apply
```

For each entry in the `workspaces` map, apply creates:

- UAMI in the platform subscription (`rg-terraform-identities`)
- Federated credentials for `plan` and `apply`
- Workload resource group in that workspace's Azure subscription
- Role assignment on that RG
- Workspace env vars `TFC_AZURE_RUN_CLIENT_ID` and `ARM_SUBSCRIPTION_ID`

### Migrating existing workload RGs (azurerm → azapi)

If you previously applied with the `azurerm.workload` provider alias, remove the old state address and import into AzAPI (Azure resources stay as-is):

```bash
TFC_WS="azure-rg-bleep-dev"
WORKLOAD_RG="${TFC_WS#azure-}"
WORKLOAD_SUB="<workload-subscription-id>"

terraform state rm \
  "module.tfc_wi[\"${TFC_WS}\"].azurerm_resource_group.workload"

terraform import \
  "module.tfc_wi[\"${TFC_WS}\"].azapi_resource.workload_rg" \
  "/subscriptions/${WORKLOAD_SUB}/resourceGroups/${WORKLOAD_RG}"
```

---

## Adding a workspace

Add one map entry in [`main.tf`](main.tf) — that is the only change required:

```hcl
locals {
  workspaces = {
    "azure-rg-myapp-prod" = {
      workload_subscription_id = "<workload-sub-id>"
    }
  }
}
```

The map key is the TFC workspace name (`azure-rg-{workload}-{env}`). The workload RG is derived automatically (`rg-{workload}-{env}`).

`workload_subscription_id` is required and can differ per workspace. Ensure the platform UAMI already has Contributor + User Access Administrator on that subscription ([step 4](#4-rbac-for-the-platform-uami)).

Optional per-entry keys: `role`, `workload_rg_location`. Because Terraform map values must share the same attributes, either omit these on every entry (defaults apply) or set them on every entry.

---

## Module reference

### Inputs

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `tfc_org_name` | yes | — | HCP Terraform org name |
| `tfc_project_name` | no | `"Default Project"` | HCP Terraform project name |
| `tfc_workspace_name` | yes | — | Must match `azure-rg-{workload}-{env}` (also derives RG name) |
| `platform_resource_group` | no | `"rg-terraform-identities"` | Platform RG for the UAMI |
| `uami_location` | yes | — | Azure region for the UAMI |
| `workload_subscription_id` | yes | — | Workload Azure subscription for this workspace |
| `workload_rg_location` | no | `null` → `uami_location` | Workload RG region |
| `role` | no | `"Contributor"` | RBAC role on the workload RG |
| `create_tfc_workspace_variables` | no | `false` | Create TFC env vars automatically |
| `tags` | no | `{}` | Tags on UAMI and workload RG |

### Outputs

| Output | Description |
|--------|-------------|
| `uami_name` / `uami_client_id` / `uami_principal_id` / `uami_id` | UAMI identifiers |
| `federated_credential_ids` | Map of `plan` / `apply` → credential resource ID |
| `workload_subscription_id` | Workload subscription for this workspace |
| `workload_resource_group_name` | Derived RG name (`azure-rg-X-Y` → `rg-X-Y`) |
| `workload_resource_group_id` | Workload RG resource ID |
| `role_assignment_id` | RBAC assignment ID |
| `tfc_workspace_variables_summary` | Manual env-var values when auto-create is off |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `exec: "az": executable file not found` | OIDC env vars missing; provider fell back to Azure CLI | Complete [bootstrap step 5](#5-platform-workspace-variables) |
| `Authentication method has limited TFE provider permissions` | Using workspace run token instead of org token | Set `TFE_TOKEN` (org token) on the platform workspace |
| `Couldn't create env variable … resource not found` | Same as above | Set `TFE_TOKEN` |
| `…resourceGroups/write` AuthorizationFailed | Platform UAMI missing Contributor on that workload sub | Grant Contributor on the workspace's subscription ([step 4](#4-rbac-for-the-platform-uami)) |
| `…roleAssignments/write` AuthorizationFailed | Missing User Access Administrator on that workload sub | Grant UAA on the workspace's subscription ([step 4](#4-rbac-for-the-platform-uami)) |
| `already exists … needs to be imported` | Partial apply left Azure resources without state | Import (see below), then re-apply |
| `AADSTS70021: No matching federated identity record` | OIDC subject mismatch (org/project/workspace) | Check exact, case-sensitive names in TFC |
| `AuthorizationFailed` on data source read | RBAC propagation delay | Wait 2–5 minutes and re-run |
| Plan works, apply fails auth | Missing `run_phase:apply` federated credential | Verify both plan and apply creds exist |

### Importing orphaned resources

```bash
PLATFORM_SUB="<platform-subscription-id>"
WORKLOAD_SUB="<workload-subscription-id>"
PLATFORM_RG="rg-terraform-identities"
TFC_ORG="<hcp-terraform-org-name>"
TFC_PROJECT_SLUG="default-project"   # project name lowercased, spaces → hyphens
TFC_WS="azure-rg-bleep-dev"
WORKLOAD_RG="${TFC_WS#azure-}"
UAMI_NAME="uami-tfc-${TFC_ORG}-${TFC_PROJECT_SLUG}-${TFC_WS}"

# Platform UAMI
terraform import \
  "module.tfc_wi[\"${TFC_WS}\"].azurerm_user_assigned_identity.this" \
  "/subscriptions/${PLATFORM_SUB}/resourceGroups/${PLATFORM_RG}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${UAMI_NAME}"

# Workload RG (AzAPI)
terraform import \
  "module.tfc_wi[\"${TFC_WS}\"].azapi_resource.workload_rg" \
  "/subscriptions/${WORKLOAD_SUB}/resourceGroups/${WORKLOAD_RG}"
```

Repeat for each orphaned resource, then `terraform apply`.

---

## References

- [HCP Terraform — Dynamic Provider Credentials: Azure](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/azure-configuration)
- [AzureRM Provider — OIDC Authentication](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc)
- [AzAPI Provider](https://registry.terraform.io/providers/Azure/azapi/latest/docs)
- [Azure AD — Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Configure a UAMI to trust an external IdP](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
- [HCP Terraform — Variable Sets](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/variables/managing-variables#variable-sets)
