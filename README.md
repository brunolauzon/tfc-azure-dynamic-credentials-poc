# HCP Terraform → Azure Dynamic Provider Credentials PoC

Proof-of-concept for [HCP Terraform Dynamic Provider Credentials](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/azure-configuration) with Azure.

HCP Terraform mints a short-lived OIDC JWT per run. Azure is configured to trust that token via a **User-Assigned Managed Identity** with a federated identity credential, so the AzureRM provider exchanges it for a scoped Azure access token — **no `ARM_CLIENT_SECRET` is stored anywhere, and no App Registration or Service Principal is required**.

- **Organisation:** `<your-hcp-org>`
- **Workspace:** `<your-workspace>`
- **Project:** `<your-project>`

---

## How It Works

```
HCP TF run starts
    │
    ├─ HCP TF mints a signed JWT (workload identity token)
    ├─ Injects ARM_OIDC_TOKEN into the runner environment
    │
    └─ AzureRM provider picks up ARM_OIDC_TOKEN + ARM_TENANT_ID
           + TFC_AZURE_RUN_CLIENT_ID (UAMI client ID)
           │
           └─ Calls Azure AD /token endpoint (federated identity exchange)
                  │
                  └─ Azure returns short-lived access token (~15 min)
                         └─ Provider uses it for all API calls
```

No secret is ever stored. The token expires automatically after the run.

---

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- An Azure subscription where you have **Owner** or **Contributor + User Access Administrator**
- A resource group already created (the UAMI will live in it) 
  ```bash
  az group create --name <your-resource-group> --location <your-location>
  ```
- HCP Terraform org and workspace already created in HCP Terraform
- Terraform CLI ≥ 1.9

---

## Phase 1 — Azure Setup

Run these commands once in the Azure CLI.

### 1. Create a User-Assigned Managed Identity

```bash
az identity create \
  --name <your-uami-name> \
  --resource-group <your-resource-group> \
  --location <your-location>

UAMI_CLIENT_ID=$(az identity show \
  --name <your-uami-name> \
  --resource-group <your-resource-group> \
  --query clientId -o tsv)
```

### 2. Create Federated Identity Credentials

You need **two** — one per run phase.

```bash
az identity federated-credential create \
  --name <your-uami-name>-plan \
  --identity-name <your-uami-name> \
  --resource-group <your-resource-group> \
  --issuer "https://app.terraform.io" \
  --subject "organization:<your-hcp-org>:project:<your-project>:workspace:<your-workspace>:run_phase:plan" \
  --audience "api://AzureADTokenExchange"

az identity federated-credential create \
  --name <your-uami-name>-apply \
  --identity-name <your-uami-name> \
  --resource-group <your-resource-group> \
  --issuer "https://app.terraform.io" \
  --subject "organization:<your-hcp-org>:project:<your-project>:workspace:<your-workspace>:run_phase:apply" \
  --audience "api://AzureADTokenExchange"
```

> **Note:** `<your-project>` must match your TFC project name exactly (case-sensitive). Verify under HCP TF → Settings → Projects. The default project name is `Default Project`.

> **Note:** System-assigned managed identities do **not** support federated identity credentials. A user-assigned managed identity is required.

### 3. Assign RBAC Role and Collect IDs

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

az role assignment create \
  --assignee $UAMI_CLIENT_ID \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

echo "TFC_AZURE_RUN_CLIENT_ID  = $UAMI_CLIENT_ID"
echo "ARM_SUBSCRIPTION_ID      = $SUBSCRIPTION_ID"
echo "ARM_TENANT_ID            = $TENANT_ID"
```

> **PoC note:** `Contributor` on the subscription is sufficient here. In production, scope down to a resource group and use a least-privilege role.

---

## Phase 2 — HCP Terraform Workspace Variables

Go to your workspace → **Variables** → **+ Add variable**.

All four must be set as **Environment variable** (not Terraform variable).

| Key | Value | Sensitive |
|-----|-------|-----------|
| `TFC_AZURE_PROVIDER_AUTH` | `true` | No |
| `TFC_AZURE_RUN_CLIENT_ID` | `$UAMI_CLIENT_ID` from step 3 | No |
| `ARM_SUBSCRIPTION_ID` | `$SUBSCRIPTION_ID` from step 3 | No |
| `ARM_TENANT_ID` | `$TENANT_ID` from step 3 | No |

**Do not set `ARM_CLIENT_SECRET` or `ARM_USE_OIDC`.** Those belong to the manual OIDC approach, not HCP dynamic credentials.

When a run starts and `TFC_AZURE_PROVIDER_AUTH=true` is detected, HCP TF automatically injects `ARM_OIDC_TOKEN` into the runner. The AzureRM provider picks it up and performs the Azure AD token exchange transparently using the UAMI client ID.

---

## Phase 3 — Terraform Configuration

The provider block is intentionally minimal — no OIDC flags needed:

```hcl
provider "azurerm" {
  features {}
  # No explicit OIDC config needed — HCP Terraform injects
  # TFC_AZURE_PROVIDER_AUTH=true and TFC_AZURE_RUN_CLIENT_ID automatically.
}
```

The smoke test reads the current subscription and outputs its name:

```hcl
data "azurerm_subscription" "current" {}

output "subscription_display_name" {
  value = data.azurerm_subscription.current.display_name
}
```

---

## Running the PoC

**If the workspace is VCS-backed:**
```bash
git add .
git commit -m "feat: HCP TF dynamic credentials PoC"
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
- [ ] Azure portal → Resource Group → `<your-resource-group>` (Managed Identity) → **Federated credentials** shows two entries

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `AADSTS70021: No matching federated identity record` | Subject string mismatch | Check org/project/workspace names are exact (case-sensitive). Verify TFC project name under Settings → Projects. |
| Dynamic credentials not injected; provider falls back to static auth | `TFC_AZURE_PROVIDER_AUTH` set as Terraform var, not env var | In TFC Variables UI, category must be **Environment variable**. |
| `AuthorizationFailed` on data source read | RBAC not propagated yet | Wait 2–3 min after `az role assignment create`, then retry. |
| Plan works, apply fails auth | Only `run_phase:plan` federated credential created | Add second federated credential for `run_phase:apply` (step 2). |
| `TFC_AZURE_RUN_CLIENT_ID must be set` error | Variable typo or wrong category | Verify exact key name and that category = Environment variable. |
| Federated credential creation fails | Using a system-assigned managed identity | Only user-assigned managed identities support federated identity credentials. |

---

## References

- [HCP Terraform — Dynamic Provider Credentials: Azure](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/azure-configuration)
- [AzureRM Provider — OIDC Authentication](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc)
- [Azure AD — Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Configure a UAMI to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
