# HCP Terraform → Azure Dynamic Provider Credentials PoC

> **Module-based implementation.** The Azure setup (UAMI, federated credentials, role assignment) and optional HCP Terraform workspace variable injection are encapsulated in [`modules/tfc-azure-workload-identity`](modules/tfc-azure-workload-identity/). Adding a new workspace = one `module {}` block in [`main.tf`](main.tf). No manual Azure CLI steps required after initial prerequisites.

Proof-of-concept for [HCP Terraform Dynamic Provider Credentials](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/azure-configuration) with Azure.

HCP Terraform mints a short-lived OIDC JWT per run. Azure is configured to trust that token via a **User-Assigned Managed Identity** with a federated identity credential, so the AzureRM provider exchanges it for a scoped Azure access token — **no `ARM_CLIENT_SECRET` is stored anywhere, and no App Registration or Service Principal is required**.

All UAMIs are **centralized in a dedicated platform resource group** (`rg-terraform-identities`) isolated from workload subscriptions. Workload teams have no role on that resource group and cannot create, assign, or modify identities. Each UAMI maps 1-to-1 to one TFC workspace.

- **Organisation:** `<your-hcp-org>`
- **Workspace:** `<your-workspace>`
- **Project:** `<your-project>`

---

## Module Structure

```
.
├── main.tf                                      ← root: one module call per TFC workspace
└── modules/
    └── tfc-azure-workload-identity/
        ├── versions.tf                          ← provider requirements (azurerm ~> 4.0, tfe ~> 0.63)
        ├── variables.tf                         ← all inputs with validation
        ├── main.tf                              ← UAMI + fed creds + role assignment + optional TFC vars
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

### Module Inputs

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `tfc_org_name` | yes | — | HCP Terraform org name |
| `tfc_project_name` | no | `"Default Project"` | HCP Terraform project name |
| `tfc_workspace_name` | yes | — | Must match `azure-rg-{workload}-{env}` |
| `platform_resource_group` | no | `"rg-terraform-identities"` | Platform RG where UAMI is created |
| `uami_location` | yes | — | Azure region for the UAMI |
| `workload_subscription_id` | yes | — | Subscription where role is assigned |
| `workload_resource_group` | yes | — | Workload RG the UAMI gets access to |
| `role` | no | `"Contributor"` | RBAC role on the workload RG |
| `create_tfc_workspace_variables` | no | `false` | Auto-create `TFC_AZURE_RUN_CLIENT_ID` + `ARM_SUBSCRIPTION_ID` in TFC |

### Adding a New Workspace

```hcl
module "tfc_wi_myapp_prod" {
  source = "./modules/tfc-azure-workload-identity"

  tfc_org_name       = "<your-hcp-org>"
  tfc_project_name   = "Default Project"
  tfc_workspace_name = "azure-rg-myapp-prod"     # ← only input that changes per workspace

  platform_resource_group  = "rg-terraform-identities"
  uami_location            = var.uami_location

  workload_subscription_id = var.workload_subscription_id
  workload_resource_group  = "rg-myapp-prod"
  role                     = "Contributor"

  create_tfc_workspace_variables = true
}
```

---

## Architecture

```
Subscription: platform-infra         ← platform team only, no workload team has any role here
  └─ rg-terraform-identities
       ├─ uami-tfc-<org>-<project>-<workspace-A>
       │    ├─ Fed. Cred: run_phase:plan  (subject locked to workspace-A)
       │    └─ Fed. Cred: run_phase:apply (subject locked to workspace-A)
       ├─ uami-tfc-<org>-<project>-<workspace-B>
       │    ├─ Fed. Cred: run_phase:plan
       │    └─ Fed. Cred: run_phase:apply
       └─ ...

                │ Role Assignment (cross-subscription, scoped to target RG)
                ▼
Subscription: workload-prod
  └─ rg-app-team-a
       └─ Contributor ← granted to uami-tfc-...-workspace-A only
```

Workload teams cannot create UAMIs in their subscriptions — an Azure Policy `Deny` on
`Microsoft.ManagedIdentity/userAssignedIdentities` is assigned at the workload management group.

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
           ARM_OIDC_TOKEN          (injected by HCP TF)
           ARM_TENANT_ID           (from Variable Set — shared)
           ARM_SUBSCRIPTION_ID     (from workspace variable)
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

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- **Platform subscription** where you have `Owner` or `Contributor + User Access Administrator` — the UAMI lives here
- **Workload subscription** where the UAMI will be granted a role — you need `User Access Administrator` there to create the role assignment
- Platform resource group created for all Terraform identities:
  ```bash
  az group create --name rg-terraform-identities --location <your-location>
  ```
- HCP Terraform org and workspace already created in HCP Terraform
- Terraform CLI ≥ 1.9

---

## Phase 1 — Prerequisites (one-time CLI)

> The UAMI, federated credentials, role assignment, and TFC workspace variables are now all managed by the module. Only two one-time CLI steps remain.

### 1. Create the platform resource group

```bash
az group create \
  --name rg-terraform-identities \
  --location <your-location>
```

### 2. Apply Policy Guardrail (once, per workload management group)

Block workload teams from creating their own UAMIs outside the platform resource group:

```bash
WORKLOAD_SUBSCRIPTION_ID=$(az account show --subscription <your-workload-subscription> --query id -o tsv)

az policy assignment create \
  --name "deny-uami-in-workload-subs" \
  --display-name "Deny UAMI creation outside platform RG" \
  --policy "$(az policy definition list --query "[?displayName=='No managed identity in subscription'].name" -o tsv)" \
  --scope "/subscriptions/$WORKLOAD_SUBSCRIPTION_ID"
```

> **Tip:** For a fleet of workload subscriptions, assign at the management group level and exclude the platform subscription from scope.

---

## Phase 2 — Deploy with Terraform

```bash
# Never commit these values — use env vars or a .tfvars file (already in .gitignore)
export TF_VAR_platform_subscription_id="<platform-sub-id>"
export TF_VAR_workload_subscription_id="<workload-sub-id>"
export TFE_TOKEN="<your-hcp-terraform-token>"    # only needed when create_tfc_workspace_variables = true

terraform init
terraform plan
terraform apply
```

After apply, the `workload_identities` output surfaces UAMI names and client IDs for all provisioned workspaces.

---

## Phase 3 — HCP Terraform Variables

Variables are split across two layers to avoid repeating common values in every workspace.

### Variable Set (shared — set once, attached to the project or org)

Go to **Settings → Variable Sets → + New variable set**, then attach it to your project.

All must be set as **Environment variable**.

| Key | Value | Sensitive |
|-----|-------|-----------|
| `TFC_AZURE_PROVIDER_AUTH` | `true` | No |
| `ARM_TENANT_ID` | Your Azure tenant ID | No |

> When `create_tfc_workspace_variables = true`, `TFC_AZURE_RUN_CLIENT_ID` and `ARM_SUBSCRIPTION_ID` are created automatically by the module. Only the Variable Set above requires manual setup.

**Do not set `ARM_CLIENT_SECRET` or `ARM_USE_OIDC`.** Those belong to the manual OIDC approach, not HCP dynamic credentials.

When a run starts and `TFC_AZURE_PROVIDER_AUTH=true` is detected, HCP TF automatically injects `ARM_OIDC_TOKEN` into the runner. The AzureRM provider picks it up and performs the Azure AD token exchange transparently using the UAMI client ID.

---

## Phase 4 — Running a Workspace Run

**If the workspace is VCS-backed:**
```bash
git add .
git commit -m "feat: add workload identity for azure-rg-fibre-dev"
git push
```

**If CLI-driven:**
```bash
terraform login   # one-time browser auth
terraform init
terraform plan
```

---

## Verification Checklist

- [ ] Plan output shows `subscription_display_name = "..."` — confirms Azure auth worked
- [ ] TFC run logs show *Configuring Azure Dynamic Provider Credentials*
- [ ] No `ARM_CLIENT_SECRET` variable exists in TFC
- [ ] Azure portal → `rg-terraform-identities` → UAMI → **Federated credentials** shows exactly two entries (plan + apply)
- [ ] UAMI does **not** exist in the workload resource group — only in `rg-terraform-identities`
- [ ] Workload team has no role on `rg-terraform-identities` (verify under Access Control (IAM))
- [ ] Azure Policy assignment is active on the workload subscription — test by attempting `az identity create` in the workload RG (should be denied)

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `AADSTS70021: No matching federated identity record` | Subject string mismatch | Check org/project/workspace names are exact (case-sensitive). Verify TFC project name under Settings → Projects. |
| Dynamic credentials not injected; provider falls back to static auth | `TFC_AZURE_PROVIDER_AUTH` set as Terraform var, not env var | In TFC Variables UI, category must be **Environment variable**. |
| `AuthorizationFailed` on data source read | RBAC not propagated yet or role scoped to wrong RG | Wait 2–3 min after `az role assignment create`. Confirm scope is `$WORKLOAD_RG_ID`, not the platform subscription. |
| Plan works, apply fails auth | Only `run_phase:plan` federated credential created | Add second federated credential for `run_phase:apply` (step 2). |
| `TFC_AZURE_RUN_CLIENT_ID must be set` error | Variable typo, wrong category, or missing workspace variable | Verify exact key name, category = Environment variable, and that it is set at workspace level (not only in the Variable Set). |
| Federated credential creation fails | Using a system-assigned managed identity | Only user-assigned managed identities support federated identity credentials. |
| Policy denies UAMI creation in `rg-terraform-identities` | Policy assignment scope incorrectly includes the platform subscription | Verify the policy is assigned only to the workload management group / subscription, not the platform subscription. |

---

## References

- [HCP Terraform — Dynamic Provider Credentials: Azure](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/azure-configuration)
- [AzureRM Provider — OIDC Authentication](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc)
- [Azure AD — Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Configure a UAMI to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
- [Azure Policy — Built-in definitions for Managed Identity](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies)
- [HCP Terraform — Variable Sets](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/variables/managing-variables#variable-sets)
