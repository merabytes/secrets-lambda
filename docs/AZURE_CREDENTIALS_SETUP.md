# Azure Credentials Setup for Multi-Region Deployment

This guide explains how to generate Azure Key Vault credentials for all regions using the automated setup script.

## Quick Start

### Prerequisites

1. **Azure CLI** logged in (`az login`)
2. **Azure subscription** with appropriate permissions
3. **install.sh** script in the repository root

### Generate Credentials

```bash
# Generate Azure credentials for all regions
./scripts/setup-azure-credentials.sh --azure-subscription YOUR_SUBSCRIPTION_ID
```

This will:
1. Create Azure Key Vaults in all specified regions
2. Create Service Principals for each region
3. Generate a single consolidated credentials file: `azure-credentials.env`

### Output Format

The script generates a single file with all credentials in the format:

```bash
# Region: eastus (East US)
export EASTUS_AZURE_TENANT_ID="..."
export EASTUS_AZURE_CLIENT_ID="..."
export EASTUS_AZURE_CLIENT_SECRET="..."
export EASTUS_AZURE_KEY_VAULT_NAME="merabyteseastus"

# Region: westeurope (West Europe)
export WESTEUROPE_AZURE_TENANT_ID="..."
export WESTEUROPE_AZURE_CLIENT_ID="..."
export WESTEUROPE_AZURE_CLIENT_SECRET="..."
export WESTEUROPE_AZURE_KEY_VAULT_NAME="merabyteswesteurope"

# ... (one section per region)
```

## Configuration Options

### Selective Regions

Generate credentials for specific regions only:

```bash
./scripts/setup-azure-credentials.sh \
  --azure-subscription YOUR_SUB_ID \
  --azure-regions eastus,westeurope,southeastasia
```

### Custom Project Name

Use a different project name (default is "merabytes"):

```bash
./scripts/setup-azure-credentials.sh \
  --azure-subscription YOUR_SUB_ID \
  --project-name mycompany
```

This creates resources like:
- Resource Group: `mycompanyeastus`
- Key Vault: `mycompanyeastus`
- Service Principal: `mycompany-eastus`

### Custom Output File

Specify a different output file:

```bash
./scripts/setup-azure-credentials.sh \
  --azure-subscription YOUR_SUB_ID \
  --output-file my-credentials.env
```

### Dry Run

See what would be created without actually creating resources:

```bash
./scripts/setup-azure-credentials.sh \
  --azure-subscription YOUR_SUB_ID \
  --dry-run
```

## Adding Credentials to GitHub Secrets

After running the script, you need to add the credentials to GitHub Secrets:

1. View the generated credentials:
   ```bash
   cat azure-credentials.env
   ```

2. Go to your GitHub repository:
   - Settings → Secrets and variables → Actions

3. Add each credential as a new secret:
   - Secret name: `EASTUS_AZURE_TENANT_ID`
   - Secret value: Copy from the env file

4. Repeat for all regions you want to deploy to

### Helper Script

You can use this script to list all secrets that need to be added:

```bash
# Extract secret names from the credentials file
grep "^export" azure-credentials.env | cut -d'=' -f1 | sed 's/export //' | sort
```

## Supported Regions

The script supports all major Azure regions with AWS region mapping:

| Azure Region | AWS Mapping | Location |
|--------------|-------------|----------|
| eastus | us-east-1 | Virginia, USA |
| eastus2 | us-east-2 | Virginia, USA |
| westus | us-west-1 | California, USA |
| westus2 | us-west-2 | Washington, USA |
| northeurope | eu-west-1 | Ireland |
| westeurope | eu-west-1 | Netherlands |
| uksouth | eu-west-2 | London, UK |
| francecentral | eu-west-3 | Paris, France |
| germanywestcentral | eu-central-1 | Frankfurt, Germany |
| switzerlandnorth | eu-central-2 | Zurich, Switzerland |
| swedencentral | eu-north-1 | Sweden |
| italynorth | eu-south-1 | Milan, Italy |
| japaneast | ap-northeast-1 | Tokyo, Japan |
| japanwest | ap-northeast-3 | Osaka, Japan |
| koreacentral | ap-northeast-2 | Seoul, South Korea |
| southeastasia | ap-southeast-1 | Singapore |
| australiaeast | ap-southeast-2 | Sydney, Australia |
| indonesiacentral | ap-southeast-3 | Jakarta, Indonesia |
| malaysiawest | ap-southeast-5 | Kuala Lumpur, Malaysia |
| centralindia | ap-south-1 | Pune, India |
| southindia | ap-south-2 | Chennai, India |
| eastasia | ap-east-1 | Hong Kong |
| canadacentral | ca-central-1 | Toronto, Canada |
| canadaeast | ca-west-1 | Quebec, Canada |
| brazilsouth | sa-east-1 | São Paulo, Brazil |
| uaenorth | me-central-1 | Dubai, UAE |
| southafricanorth | af-south-1 | Johannesburg, South Africa |
| israelcentral | il-central-1 | Israel |
| mexicocentral | mx-central-1 | Mexico |

## Next Steps

After generating credentials:

1. **Add to GitHub Secrets**: Configure all `{REGION}_AZURE_*` secrets
2. **Create Lambda Functions**: Manually create Lambda functions in AWS regions
3. **Deploy**: Push to main branch to trigger the deployment workflow
4. **Verify**: Check GitHub Actions logs for deployment status

## Workflow Integration

The deployment workflow (`.github/workflows/deploy.yml`) will:
1. Build Docker image once
2. Deploy to all AWS regions with configured secrets
3. Skip regions without GitHub Secrets (gracefully)
4. Skip regions without Lambda functions (with warning)
5. Update Lambda functions with new image
6. Configure region-specific Azure Key Vault credentials

## Troubleshooting

### Script Fails for a Region

If the script fails for a specific region:
- Check Azure region availability
- Verify you have permissions in that region
- Some regions may require subscription opt-in

### Key Vault Name Too Long

If the Key Vault name exceeds 24 characters:
- Use a shorter project name: `--project-name mb`
- Or the script will automatically truncate it

### Missing Permissions

Ensure your Azure account has:
- Permission to create Resource Groups
- Permission to create Service Principals
- Permission to create Key Vaults
- Subscription-level Contributor or Owner role

## Manual Cleanup

To remove all resources created:

```bash
# List all resource groups
az group list --query "[?starts_with(name, 'merabytes')].name" -o tsv

# Delete specific resource group
az group delete --name merabyteseastus --yes --no-wait

# Delete all merabytes resource groups
for rg in $(az group list --query "[?starts_with(name, 'merabytes')].name" -o tsv); do
  az group delete --name "$rg" --yes --no-wait
done
```

---

**Last Updated**: 2025-11-06
