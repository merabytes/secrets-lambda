# All-Regions Setup Guide

This guide explains how to set up the secrets-lambda service across **ALL** AWS and Azure regions using the automated setup scripts.

## Overview

The comprehensive multi-region setup includes:
- **AWS**: 28 regions (US, Europe, Asia Pacific, Middle East, Africa, South America)
- **Azure**: 60+ regions mapped to corresponding AWS regions
- **Automated**: Single script to provision everything
- **Flexible**: Choose specific regions or deploy to all

## Quick Start

### Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Azure CLI** logged in (`az login`)
3. **Permissions**: Admin access to both AWS and Azure subscriptions

### One-Command Setup (All Regions)

```bash
# Setup ALL regions (AWS + Azure)
./scripts/setup-all-regions.sh --azure-subscription YOUR_SUBSCRIPTION_ID
```

This will:
1. Create ECR repository in us-east-1 (shared across all regions)
2. Create Lambda functions in all 28 AWS regions
3. Create Azure Key Vaults in all mapped Azure regions
4. Generate environment files for each region
5. Create a consolidated credentials file

### Selective Setup

```bash
# Setup only specific AWS regions
./scripts/setup-all-regions.sh \
  --azure-subscription YOUR_SUB_ID \
  --aws-regions us-east-1,eu-west-1,ap-southeast-1

# Setup only Azure resources
./scripts/setup-all-regions.sh \
  --azure-subscription YOUR_SUB_ID \
  --skip-aws

# Setup only AWS resources
./scripts/setup-all-regions.sh --skip-azure

# Dry run to see what would be created
./scripts/setup-all-regions.sh \
  --azure-subscription YOUR_SUB_ID \
  --dry-run
```

## Complete Region List

### AWS Regions (28 total)

| Region | Location | Azure Mapping |
|--------|----------|---------------|
| us-east-1 | N. Virginia | eastus |
| us-east-2 | Ohio | eastus2 |
| us-west-1 | N. California | westus |
| us-west-2 | Oregon | westus2 |
| ca-central-1 | Canada Central | canadacentral |
| ca-west-1 | Canada West | canadaeast |
| eu-west-1 | Ireland | northeurope |
| eu-west-2 | London | uksouth |
| eu-west-3 | Paris | francecentral |
| eu-central-1 | Frankfurt | germanywestcentral |
| eu-central-2 | Zurich | switzerlandnorth |
| eu-north-1 | Stockholm | swedencentral |
| eu-south-1 | Milan | italynorth |
| ap-northeast-1 | Tokyo | japaneast |
| ap-northeast-2 | Seoul | koreacentral |
| ap-northeast-3 | Osaka | japanwest |
| ap-southeast-1 | Singapore | southeastasia |
| ap-southeast-2 | Sydney | australiaeast |
| ap-southeast-3 | Jakarta | indonesiacentral |
| ap-southeast-5 | Malaysia | malaysiawest |
| ap-south-1 | Mumbai | centralindia |
| ap-south-2 | Hyderabad | southindia |
| ap-east-1 | Hong Kong | eastasia |
| sa-east-1 | São Paulo | brazilsouth |
| me-central-1 | UAE | uaenorth |
| af-south-1 | Cape Town | southafricanorth |
| il-central-1 | Tel Aviv | israelcentral |
| mx-central-1 | Mexico | mexicocentral |

### Azure Regions (60+ available)

The script supports all Azure regions. Key regions include:
- **US**: eastus, eastus2, westus, westus2, westus3, centralus, northcentralus, southcentralus, westcentralus
- **Europe**: northeurope, westeurope, germanywestcentral, francecentral, uksouth, norwayeast, swedencentral, switzerlandnorth, italynorth
- **Asia Pacific**: southeastasia, eastasia, japaneast, japanwest, koreacentral, australiaeast, centralindia, southindia
- **Others**: brazilsouth, canadacentral, southafricanorth, uaenorth, israelcentral

## Resource Naming Convention

The script uses a consistent naming pattern for all resources:

### Azure Resources

- **Resource Group**: `{project-name}{region}` (e.g., `merabyteseastus`)
- **Key Vault**: `{project-name}{region}` (truncated to 24 chars, e.g., `merabyteseastus`)
- **Service Principal**: `{project-name}-{region}` (e.g., `merabytes-eastus`)

### AWS Resources

- **ECR Repository**: `acido-secrets` (single, in us-east-1)
- **Lambda Function**: `AcidoSecrets` (one per region)
- **IAM Role**: `AcidoSecretsLambdaRole` (shared across regions)

## Output Structure

After running the setup script, you'll find:

```
regions/
├── australiaeast.env
├── australiasoutheast.env
├── brazilsouth.env
├── canadacentral.env
├── centralindia.env
├── eastasia.env
├── eastus.env
├── eastus2.env
├── ... (one per Azure region)
└── all-regions-credentials.txt  # Consolidated credentials
```

Each `.env` file contains:
```bash
export AZURE_SUBSCRIPTION_ID="..."
export AZURE_RESOURCE_GROUP="merabyteseastus"
export AZURE_CLIENT_ID="..."
export AZURE_TENANT_ID="..."
export AZURE_CLIENT_SECRET="..."
export KEY_VAULT_NAME="merabyteseastus"
```

## GitHub Secrets Configuration

After setup, you need to configure GitHub Secrets for each region:

### For Each Region

```
{REGION}_AZURE_TENANT_ID
{REGION}_AZURE_CLIENT_ID
{REGION}_AZURE_CLIENT_SECRET
{REGION}_AZURE_KEY_VAULT_NAME
```

### Region Code Format

The Azure region code for GitHub Secrets is **UPPERCASE** programmatic name:
- `eastus` → `EASTUS`
- `germanywestcentral` → `GERMANYWESTCENTRAL`
- `southeastasia` → `SOUTHEASTASIA`

### Helper Script

Use the provided script to extract secrets from env files:

```bash
# Generate GitHub secrets from env files
for file in regions/*.env; do
  region=$(basename "$file" .env)
  echo "# Region: $region"
  echo "${region}_AZURE_TENANT_ID=$(grep AZURE_TENANT_ID "$file" | cut -d'=' -f2 | tr -d '"')"
  echo "${region}_AZURE_CLIENT_ID=$(grep AZURE_CLIENT_ID "$file" | cut -d'=' -f2 | tr -d '"')"
  echo "${region}_AZURE_CLIENT_SECRET=$(grep AZURE_CLIENT_SECRET "$file" | cut -d'=' -f2 | tr -d '"')"
  echo "${region}_AZURE_KEY_VAULT_NAME=$(grep KEY_VAULT_NAME "$file" | cut -d'=' -f2 | tr -d '"')"
  echo ""
done
```

## Deployment Workflows

Two deployment workflows are available:

### 1. Original Workflow (6 regions)
`.github/workflows/deploy.yml`
- Deploys to 6 pre-selected regions
- Fast and efficient
- Use for initial setup

### 2. All-Regions Workflow (28 regions)
`.github/workflows/deploy-all-regions.yml`
- Deploys to all configured regions
- Skips regions without GitHub Secrets
- Use for comprehensive global coverage

To use the all-regions workflow:
```bash
# Rename or delete the original deploy.yml, then
mv .github/workflows/deploy-all-regions.yml .github/workflows/deploy.yml
```

## Cost Estimation

### Per Region Costs

**AWS (per region):**
- Lambda: $0.20 per 1M requests
- No idle cost with Function URL

**Azure (per region):**
- Key Vault: $0.03 per 10,000 operations
- Storage: Minimal for secrets

**Total estimated (28 regions):**
- Low traffic: $50-100/month
- Medium traffic: $200-500/month
- High traffic: $1000+/month

## Advanced Configuration

### Custom Project Name

```bash
./scripts/setup-all-regions.sh \
  --azure-subscription YOUR_SUB_ID \
  --project-name mycompany
```

This creates resources like:
- `mycompanyeastus` (resource group)
- `mycompany-eastus` (service principal)

### Custom Output Directory

```bash
./scripts/setup-all-regions.sh \
  --azure-subscription YOUR_SUB_ID \
  --output-dir ./credentials
```

### Specific Regions Only

```bash
# Setup only US and Europe regions
./scripts/setup-all-regions.sh \
  --azure-subscription YOUR_SUB_ID \
  --aws-regions us-east-1,us-west-2,eu-west-1,eu-central-1 \
  --azure-regions eastus,westus2,northeurope,germanywestcentral
```

## Troubleshooting

### AWS Region Not Available

Some AWS regions require opt-in:
```bash
# Enable opt-in region
aws account enable-region --region-name ap-east-1
```

### Azure Resource Group Name Too Long

If the resource group name exceeds Azure limits, use a shorter project name:
```bash
./scripts/setup-all-regions.sh \
  --azure-subscription YOUR_SUB_ID \
  --project-name mb  # Shorter name
```

### Lambda Creation Fails

Ensure you have:
1. Pushed a Docker image to ECR first
2. Or the script will create Lambda with placeholder image (update later via CI/CD)

### Missing Azure Permissions

Ensure your Azure account has:
- Permission to create Resource Groups
- Permission to create Service Principals
- Permission to create Key Vaults
- Subscription-level Contributor or Owner role

## Next Steps

After running the setup:

1. **Configure GitHub Secrets**: Add all region-specific secrets to your GitHub repository
2. **Build Docker Image**: Build and push your application to ECR
3. **Deploy**: Push to main branch to trigger deployment
4. **Test**: Use the health check endpoint in each region
5. **Monitor**: Set up monitoring and alerts

## Example: Full Setup Flow

```bash
# 1. Run setup script
./scripts/setup-all-regions.sh \
  --azure-subscription abc-123-def-456 \
  --project-name merabytes

# 2. Extract and configure GitHub secrets
# (Use the helper script above or manually add to GitHub)

# 3. Build and push Docker image
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin YOUR_ECR_URI

docker build -t YOUR_ECR_URI/acido-secrets:latest .
docker push YOUR_ECR_URI/acido-secrets:latest

# 4. Deploy via CI/CD
git push origin main

# 5. Get all function URLs
./scripts/get-function-urls.sh
```

## Cleanup

To remove all resources:

```bash
# Delete AWS Lambda functions
for region in us-east-1 us-west-2 eu-west-1; do
  aws lambda delete-function \
    --function-name AcidoSecrets \
    --region $region
done

# Delete Azure resources
for file in regions/*.env; do
  source "$file"
  az group delete --name "$AZURE_RESOURCE_GROUP" --yes --no-wait
done

# Delete ECR repository
aws ecr delete-repository \
  --repository-name acido-secrets \
  --region us-east-1 \
  --force
```

## Support

For issues:
1. Check the consolidated credentials file: `regions/all-regions-credentials.txt`
2. Review individual region env files in `regions/`
3. Check GitHub Actions logs for deployment issues
4. Verify Azure Key Vault access logs

## Security Considerations

- ✅ Each region has isolated Azure credentials
- ✅ Service Principal secrets rotated during setup
- ✅ Secrets stored in Azure Key Vault with RBAC
- ✅ GitHub Secrets for CI/CD deployment
- ⚠️ Store env files securely (they contain secrets)
- ⚠️ Rotate Service Principal secrets regularly
- ⚠️ Monitor Key Vault access logs

---

**Last Updated**: 2025-11-06
