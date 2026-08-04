# HCP Terraform → Azure Dynamic Provider Credentials PoC

Proof-of-concept for [HCP Terraform Dynamic Provider Credentials](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/azure-configuration) with Azure.

HCP Terraform mints a short-lived OIDC JWT per run. Azure is configured to trust that token via a **User-Assigned Managed Identity (UAMI)** with a federated identity credential, so the AzureRM provider exchanges it for a scoped Azure access token — **no `ARM_CLIENT_SECRET` is stored anywhere, and no App Registration or Service Principal is required**.

All UAMIs are **centralised in a dedicated platform resource group** (`rg-terraform-identities`) isolated from workload subscriptions. Each UAMI maps 1-to-1 to one HCP Terraform workspace. Workload resource groups are also managed by the platform team and created by this config.

---

## Module Structure

```
.
├── main.tf                                      ← root: workspace map + shared variable set + one module call per workspace
├── providers.tf                                 ← azurerm (platform), azurerm.workload, tfe
├── variables.tf                                 ← platform_subscription_id, workload_subscription_id, uami_location
├── versions.tf                                  ← terraform cloud{} block, required_providers
└── modules/
    └── tfc-azure-workload-identity/
        ├── versions.tf                          ← provider requirements + configuration_aliases
        ├── variables.tf                         ← all inputs with validation
        ├── main.tf                              ← UAMI + fed creds + workload RG + role assignment + optional TFC vars
        └── outputs.tf                           ← uami_name, uami_client_id, tfc_workspace_variables_summary
```

### Naming Convention

| Artifact | Pattern | Example |
|----------|---------|---------|
| TFC workspace | `azure-rg-{workload}-{env}` | `azure-rg-fibre-dev` |
| UAMI | `uami-tfc-{org}-{project}-{workspace}` | `uami-tfc-acme-default-project-azure-rg-fibre-dev` |
| Fed cred (plan) | `{uami-name}-plan` | `uami-tfc-...-azure-rg-fibre-dev-plan` |
| Fed cred (apply) | `{uami-name}-apply` | `uami-tfc-...-azure-rg-fibre-dev-apply` |
| Workload RG | `rg-{workload}-{env}` | `rg-fibre-dev` |

`tfc_workspace_name` is the **single source of truth** — all other names and OIDC subjects are derived from it automatically.

### Adding a New Workspace

Add one entry to the `workspaces` map in [`main.tf`](main.tf) — that is the only change required:

```hcl
locals {
  workspaces = {
    "azure-rg-myapp-prod" = {
      workload_subscription_id = "<workload-sub-id>"
      workload_resource_group  = "rg-myapp-prod"
      role                     = "Contributor"
    }
  }
}
```

### Module Inputs

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `tfc_org_name` | yes | — | HCP Terraform org name |
| `tfc_project_name` | no | `"Default Project"` | HCP Terraform project name |
| `tfc_workspace_name` | yes | — | Must match `azure-rg-{workload}-{env}` |
| `platform_resource_group` | no | `"rg-terraform-identities"` | Platform RG where UAMI is created |
| `uami_location` | yes | — | Azure region for the UAMI |
| `workload_subscription_id` | yes | — | Subscription where the workload RG and role assignment are created |
| `workload_resource_group` | yes | — | Name of the workload RG to create |
| `workload_rg_location` | no | `""` (falls back to `uami_location`) | Azure region for the workload RG |
| `role` | no | `"Contributor"` | RBAC role granted to the UAMI on the workload RG |
| `create_tfc_workspace_variables` | no | `false` | Auto-create `TFC_AZURE_RUN_CLIENT_ID` + `ARM_SUBSCRIPTION_ID` in HCP Terraform |

---

## Architecture

```
Subscription: platform  (bd99adad-...)       ← platform team only
  └─ rg-terraform-identities
       ├─ uami-tfc-<org>-<project>-<workspace-A>
       │    ├─ Fed. Cred: run_phase:plan   (subject locked to workspace-A)
       │    └─ Fed. Cred: run_phase:apply  (subject locked to workspace-A)
       └─ uami-tfc-<org>-<project>-<workspace-B>
            ├─ Fed. Cred: run_phase:plan
            └─ Fed. Cred: run_phase:apply

              │ Role Assignment (cross-subscription, scoped to workload RG)
              ▼
Subscription: workload  (e21b59f3-...)
  ├─ rg-workload-a    ← created by this config (azurerm.workload provider)
  │    └─ Contributor granted to uami-...-workspace-A only
  └─ rg-workload-b
       └─ Contributor granted to uami-...-workspace-B only
```

Two `azurerm` provider configurations are used:

| Provider alias | Subscription | Used for |
|---|---|---|
| `azurerm` (default) | platform (`bd99adad-...`) | UAMI, federated credentials |
| `azurerm.workload` | workload (`e21b59f3-...`) | Workload RG, role assignment |

The module declares `configuration_aliases = [azurerm.workload]` in its `versions.tf` and the root passes both aliases via the `providers` block on the module call.

---

## How It Works

```
HCP TF run starts (workspace-A)
    │
    ├─ HCP TF mints a signed JWT
    │    subject: "organization:<org>:project:<project>:workspace:<workspace-A>:run_phase:apply"
    │
    ├─ Injects ARM_OIDC_TOKEN into the runner environment
    │
    └─ AzureRM provider reads:
           ARM_OIDC_TOKEN          (injected automatically by HCP TF)
           TFC_AZURE_PROVIDER_AUTH (from Variable Set — signals dynamic creds mode)
           ARM_TENANT_ID           (from Variable Set — shared across all workspaces)
           ARM_SUBSCRIPTION_ID     (from workspace variable — unique per workspace)
           TFC_AZURE_RUN_CLIENT_ID (from workspace variable — unique per workspace)
               │
               └─ Calls Azure AD /token endpoint
                      Azure validates issuer + subject against uami-tfc-...-workspace-A
                      │
                      └─ Returns short-lived access token (~15 min)
                             └─ Provider uses it for all API calls
```

No secret is ever stored. The token expires automatically after the run.
The OIDC subject is workspace-scoped — a compromised workspace cannot impersonate any other workspace's UAMI.

---

## Bootstrap: One-Time Manual Setup

This config runs **inside the `azure-workload-identity` HCP Terraform workspace**. That workspace itself needs Azure credentials before Terraform can run for the first time. This is a bootstrap problem that must be solved once manually.

### Step 1 — Create the platform resource group

```bash
az group create \
  --name rg-terraform-identities \
  --location canadacentral \
  --subscription bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe
```

### Step 2 — Create a UAMI for the platform workspace itself

This is the identity the `azure-workload-identity` workspace uses to run Terraform. It is **separate** from the per-workspace UAMIs the module creates.

```bash
# Create the UAMI
az identity create \
  --name "uami-tfc-platform" \
  --resource-group "rg-terraform-identities" \
  --location "canadacentral" \
  --subscription bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe

# Record the client_id and principal_id (object_id)
az identity show \
  --name "uami-tfc-platform" \
  --resource-group "rg-terraform-identities" \
  --subscription bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe \
  --query "{clientId:clientId, principalId:principalId}" -o json
```

### Step 3 — Add federated credentials for plan and apply

Replace `<your-org>` with your HCP Terraform organisation name (e.g. `brunolauzon-hcp`).

```bash
az identity federated-credential create \
  --name "tfc-platform-plan" \
  --identity-name "uami-tfc-platform" \
  --resource-group "rg-terraform-identities" \
  --subscription bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe \
  --issuer "https://app.terraform.io" \
  --subject "organization:<your-org>:project:Default Project:workspace:azure-workload-identity:run_phase:plan" \
  --audience "api://AzureADTokenExchange"

az identity federated-credential create \
  --name "tfc-platform-apply" \
  --identity-name "uami-tfc-platform" \
  --resource-group "rg-terraform-identities" \
  --subscription bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe \
  --issuer "https://app.terraform.io" \
  --subject "organization:<your-org>:project:Default Project:workspace:azure-workload-identity:run_phase:apply" \
  --audience "api://AzureADTokenExchange"
```

### Step 4 — Grant the platform UAMI rights on both subscriptions

The platform workspace needs to create UAMIs on the platform subscription and resource groups + role assignments on the workload subscription:

```bash
PLATFORM_UAMI_OBJECT_ID="<principalId from Step 2>"

# Contributor on the platform subscription (to create UAMIs)
az role assignment create \
  --assignee "$PLATFORM_UAMI_OBJECT_ID" \
  --role "Contributor" \
  --scope "/subscriptions/bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe"

# Contributor on the workload subscription (to create resource groups)
az role assignment create \
  --assignee "$PLATFORM_UAMI_OBJECT_ID" \
  --role "Contributor" \
  --scope "/subscriptions/e21b59f3-d80c-435e-a2e3-0b7a77770e38"

# User Access Administrator on the workload subscription (to create role assignments)
az role assignment create \
  --assignee "$PLATFORM_UAMI_OBJECT_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/e21b59f3-d80c-435e-a2e3-0b7a77770e38"
```

> **Why both `Contributor` and `User Access Administrator`?**
> `Contributor` lets the UAMI create resource groups and other resources.
> `User Access Administrator` lets it write role assignments (`Microsoft.Authorization/roleAssignments/write`).
> Neither role alone covers both actions.

### Step 5 — Set variables on the platform workspace in HCP Terraform

In HCP Terraform → workspace `azure-workload-identity` → Variables, add the following **Environment variables**:

| Key | Value | Sensitive |
|-----|-------|-----------|
| `TFC_AZURE_PROVIDER_AUTH` | `true` | No |
| `ARM_TENANT_ID` | Your Azure AD tenant ID | No |
| `ARM_SUBSCRIPTION_ID` | `bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe` (platform sub) | No |
| `TFC_AZURE_RUN_CLIENT_ID` | `<clientId from Step 2>` | No |
| `TFE_TOKEN` | `<HCP Terraform org-level API token>` | **Yes** |

> **Why `TFE_TOKEN`?**  
> The `tfe` provider uses the workspace's built-in run token by default, but that token only has rights to its own workspace. An org-level token is required so this workspace can write variables into the workload workspaces it manages.  
> Generate one at: **HCP Terraform → Organization Settings → API Tokens → Organization Token → Create**.

### Step 6 — Create the shared variable set

In HCP Terraform → **Settings → Variable Sets → New variable set**:

- Name: `azure-workload-identity`
- Scope: attach to the workload workspaces (`azure-rg-*`)
- Add these **Environment variables**:

| Key | Value | Sensitive |
|-----|-------|-----------|
| `TFC_AZURE_PROVIDER_AUTH` | `true` | No |
| `ARM_TENANT_ID` | Your Azure AD tenant ID | No |

> `TFC_AZURE_RUN_CLIENT_ID` and `ARM_SUBSCRIPTION_ID` are **created automatically** by the module when `create_tfc_workspace_variables = true`. You do not need to set them manually.

---

## Deploying

After the bootstrap steps above, trigger a run from the HCP Terraform UI or push a change:

```bash
terraform init
terraform apply
```

On success, the module will have created for each workspace entry in the map:
- A UAMI in `rg-terraform-identities`
- Two federated credentials (plan + apply)
- A workload resource group in the workload subscription
- A role assignment scoped to that resource group
- `TFC_AZURE_RUN_CLIENT_ID` and `ARM_SUBSCRIPTION_ID` workspace variables in HCP Terraform

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `exec: "az": executable file not found in $PATH` | `azurerm` provider fell back to Azure CLI because OIDC env vars are missing | The platform workspace bootstrap variables are not set. Complete Step 5 above. |
| `Authentication method has limited TFE provider permissions` | `tfe` provider is using the workspace run token, not an org token | Set `TFE_TOKEN` as a sensitive env variable on the platform workspace (Step 5). |
| `Couldn't create env variable ... : resource not found` | `tfe` provider run token lacks write rights on workload workspaces | Same fix as above — set `TFE_TOKEN`. |
| `AuthorizationFailed: does not have authorization to perform action 'Microsoft.Resources/subscriptions/resourceGroups/write'` | Platform UAMI missing `Contributor` on the workload subscription | Run the `az role assignment create` from Step 4 (Contributor on workload sub). |
| `AuthorizationFailed: ... roleDefinitions/read` or `roleAssignments/write` | Platform UAMI missing `User Access Administrator` on the workload subscription | Run the `az role assignment create` from Step 4 (User Access Administrator on workload sub). |
| `already exists - to be managed via Terraform this resource needs to be imported` | A previous partial apply created resources in Azure but state was not saved | Run `terraform import` for each orphaned resource (see import commands below). |
| `AADSTS70021: No matching federated identity record` | OIDC subject string mismatch (org/project/workspace name wrong) | Check names are exact and case-sensitive. Verify TFC project name under Settings → Projects. |
| `AuthorizationFailed` on data source read | RBAC propagation delay | Wait 2–5 minutes after `az role assignment create` and re-run. |
| Plan works, apply fails auth | Only `run_phase:plan` federated credential created | Verify both plan and apply federated credentials exist (Step 3). |

### Importing orphaned resources

If a partial apply left UAMIs in Azure without Terraform state, import them:

```bash
terraform import \
  'module.tfc_wi["azure-rg-bleep-dev"].azurerm_user_assigned_identity.this' \
  '/subscriptions/bd99adad-06b5-4d1c-ace0-aa64bdf0a2fe/resourceGroups/rg-terraform-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-tfc-<org>-<project>-azure-rg-bleep-dev'
```

Repeat for each orphaned resource. Then re-run `terraform apply`.

---

## References

- [HCP Terraform — Dynamic Provider Credentials: Azure](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/azure-configuration)
- [AzureRM Provider — OIDC Authentication](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc)
- [Azure AD — Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Configure a UAMI to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
- [HCP Terraform — Variable Sets](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/variables/managing-variables#variable-sets)
