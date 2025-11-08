# Multi-Region Deployment Setup Guide

This guide will help you configure GitHub Secrets for multi-region deployment of the Secrets Lambda service.

## Overview

The multi-region deployment requires:
- **1 Docker image** built once and stored in ECR (eu-west-1)
- **6 AWS Lambda functions** deployed across different regions
- **6 Azure Key Vaults** (one per region) with region-specific credentials
- **GitHub Secrets** for AWS and Azure credentials

## Prerequisites

Before configuring GitHub Secrets, ensure you have:

1. ✅ AWS account with appropriate permissions
2. ✅ Azure account with 6 Key Vaults created (one per region)
3. ✅ Service Principals created for each Azure Key Vault
4. ✅ Lambda functions created in each AWS region
5. ✅ ECR repository created in eu-west-1

## Step 1: AWS Setup

### Create ECR Repository (if not exists)

```bash
aws ecr create-repository \
  --repository-name acido-secrets \
  --region eu-west-1
```

### Create Lambda Functions in Each Region

```bash
# Define regions
REGIONS=("eu-west-1" "eu-central-1" "us-east-1" "us-west-2" "ap-southeast-1" "ap-northeast-1")

# Create Lambda function in each region (using a base image first)
for REGION in "${REGIONS[@]}"; do
  echo "Creating Lambda in $REGION..."
  aws lambda create-function \
    --function-name AcidoSecrets \
    --package-type Image \
    --code ImageUri=YOUR_ECR_REGISTRY/acido-secrets:latest \
    --role arn:aws:iam::YOUR_ACCOUNT_ID:role/lambda-execution-role \
    --region $REGION \
    --timeout 30 \
    --memory-size 512
done
```

### Create Function URLs (Optional but Recommended)

```bash
# Create function URL for each Lambda
for REGION in "${REGIONS[@]}"; do
  echo "Creating Function URL in $REGION..."
  aws lambda create-function-url-config \
    --function-name AcidoSecrets \
    --auth-type NONE \
    --cors 'AllowOrigins=["https://secrets.merabytes.com"],AllowMethods=["POST","OPTIONS"],AllowHeaders=["Content-Type"],MaxAge=86400' \
    --region $REGION
    
  # Add permission for function URL to invoke Lambda
  aws lambda add-permission \
    --function-name AcidoSecrets \
    --statement-id FunctionURLAllowPublicAccess \
    --action lambda:InvokeFunctionUrl \
    --principal "*" \
    --function-url-auth-type NONE \
    --region $REGION
done
```

## Step 2: Azure Key Vault Setup

### Region Mapping

| AWS Region | Azure Region | Azure Region Code | Key Vault Name Example |
|------------|--------------|-------------------|------------------------|
| eu-west-1 | West Europe | WESTEUROPE | kv-secrets-westeurope |
| eu-central-1 | Germany West Central | GERMANYWESTCENTRAL | kv-secrets-germanywestcentral |
| us-east-1 | East US | EASTUS | kv-secrets-eastus |
| us-west-2 | West US 2 | WESTUS2 | kv-secrets-westus2 |
| ap-southeast-1 | Southeast Asia | SOUTHEASTASIA | kv-secrets-southeastasia |
| ap-northeast-1 | Japan East | JAPANEAST | kv-secrets-japaneast |

### Create Key Vaults

```bash
# Set your Azure resource group
RESOURCE_GROUP="rg-secrets-prod"

# Create Key Vaults in each region
az keyvault create --name kv-secrets-westeurope --resource-group $RESOURCE_GROUP --location westeurope
az keyvault create --name kv-secrets-germanywestcentral --resource-group $RESOURCE_GROUP --location germanywestcentral
az keyvault create --name kv-secrets-eastus --resource-group $RESOURCE_GROUP --location eastus
az keyvault create --name kv-secrets-westus2 --resource-group $RESOURCE_GROUP --location westus2
az keyvault create --name kv-secrets-southeastasia --resource-group $RESOURCE_GROUP --location southeastasia
az keyvault create --name kv-secrets-japaneast --resource-group $RESOURCE_GROUP --location japaneast
```

### Create Service Principals

You can either:
- **Option A**: Create one Service Principal per Key Vault (more isolated)
- **Option B**: Create one Service Principal with access to all Key Vaults (simpler)

#### Option A: One Service Principal per Key Vault

```bash
# Array of Key Vault names
VAULTS=("kv-secrets-westeurope" "kv-secrets-germanywestcentral" "kv-secrets-eastus" "kv-secrets-westus2" "kv-secrets-southeastasia" "kv-secrets-japaneast")

for VAULT in "${VAULTS[@]}"; do
  echo "Creating Service Principal for $VAULT..."
  
  # Create Service Principal
  SP_OUTPUT=$(az ad sp create-for-rbac --name "sp-secrets-$VAULT" --skip-assignment)
  
  # Extract credentials
  CLIENT_ID=$(echo $SP_OUTPUT | jq -r '.appId')
  CLIENT_SECRET=$(echo $SP_OUTPUT | jq -r '.password')
  TENANT_ID=$(echo $SP_OUTPUT | jq -r '.tenant')
  
  echo "Service Principal created:"
  echo "  Client ID: $CLIENT_ID"
  echo "  Tenant ID: $TENANT_ID"
  echo "  Client Secret: $CLIENT_SECRET (save this!)"
  
  # Grant Key Vault permissions
  az keyvault set-policy \
    --name $VAULT \
    --spn $CLIENT_ID \
    --secret-permissions get set delete list
    
  echo "Permissions granted to $VAULT"
  echo "---"
done
```

#### Option B: One Service Principal for All Key Vaults

```bash
# Create a single Service Principal
SP_OUTPUT=$(az ad sp create-for-rbac --name "sp-secrets-all-regions")

CLIENT_ID=$(echo $SP_OUTPUT | jq -r '.appId')
CLIENT_SECRET=$(echo $SP_OUTPUT | jq -r '.password')
TENANT_ID=$(echo $SP_OUTPUT | jq -r '.tenant')

echo "Service Principal created:"
echo "  Client ID: $CLIENT_ID"
echo "  Tenant ID: $TENANT_ID"
echo "  Client Secret: $CLIENT_SECRET (save this!)"

# Grant permissions to all Key Vaults
VAULTS=("kv-secrets-westeurope" "kv-secrets-germanywestcentral" "kv-secrets-eastus" "kv-secrets-westus2" "kv-secrets-southeastasia" "kv-secrets-japaneast")

for VAULT in "${VAULTS[@]}"; do
  echo "Granting permissions to $VAULT..."
  az keyvault set-policy \
    --name $VAULT \
    --spn $CLIENT_ID \
    --secret-permissions get set delete list
done
```

## Step 3: Configure GitHub Secrets

Navigate to your GitHub repository → Settings → Secrets and variables → Actions

### Global Secrets (Required)

Add the following secrets:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `AWS_ACCESS_KEY_ID` | AWS access key for deployment | `AKIA...` |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key | `wJalr...` |
| `ECR_REGISTRY` | ECR registry URL | `123456789.dkr.ecr.eu-west-1.amazonaws.com` |

### Global Secrets (Optional)

| Secret Name | Description | Default Value |
|-------------|-------------|---------------|
| `CORS_ORIGIN` | CORS origin URL | `https://secrets.merabytes.com` |
| `CF_SECRET_KEY` | CloudFlare Turnstile secret key | _(none)_ |

### Region-Specific Secrets (Required)

For each region, add 4 secrets using the Azure region code prefix:

#### West Europe (eu-west-1)
- `WESTEUROPE_AZURE_TENANT_ID`
- `WESTEUROPE_AZURE_CLIENT_ID`
- `WESTEUROPE_AZURE_CLIENT_SECRET`
- `WESTEUROPE_AZURE_KEY_VAULT_NAME` (e.g., `kv-secrets-westeurope`)

#### Germany West Central (eu-central-1)
- `GERMANYWESTCENTRAL_AZURE_TENANT_ID`
- `GERMANYWESTCENTRAL_AZURE_CLIENT_ID`
- `GERMANYWESTCENTRAL_AZURE_CLIENT_SECRET`
- `GERMANYWESTCENTRAL_AZURE_KEY_VAULT_NAME` (e.g., `kv-secrets-germanywestcentral`)

#### East US (us-east-1)
- `EASTUS_AZURE_TENANT_ID`
- `EASTUS_AZURE_CLIENT_ID`
- `EASTUS_AZURE_CLIENT_SECRET`
- `EASTUS_AZURE_KEY_VAULT_NAME` (e.g., `kv-secrets-eastus`)

#### West US 2 (us-west-2)
- `WESTUS2_AZURE_TENANT_ID`
- `WESTUS2_AZURE_CLIENT_ID`
- `WESTUS2_AZURE_CLIENT_SECRET`
- `WESTUS2_AZURE_KEY_VAULT_NAME` (e.g., `kv-secrets-westus2`)

#### Southeast Asia (ap-southeast-1)
- `SOUTHEASTASIA_AZURE_TENANT_ID`
- `SOUTHEASTASIA_AZURE_CLIENT_ID`
- `SOUTHEASTASIA_AZURE_CLIENT_SECRET`
- `SOUTHEASTASIA_AZURE_KEY_VAULT_NAME` (e.g., `kv-secrets-southeastasia`)

#### Japan East (ap-northeast-1)
- `JAPANEAST_AZURE_TENANT_ID`
- `JAPANEAST_AZURE_CLIENT_ID`
- `JAPANEAST_AZURE_CLIENT_SECRET`
- `JAPANEAST_AZURE_KEY_VAULT_NAME` (e.g., `kv-secrets-japaneast`)

**Total: 27 GitHub Secrets** (3 global + 24 region-specific)

## Step 4: Verify Setup

### Check AWS Lambda Functions

```bash
REGIONS=("eu-west-1" "eu-central-1" "us-east-1" "us-west-2" "ap-southeast-1" "ap-northeast-1")

for REGION in "${REGIONS[@]}"; do
  echo "=== $REGION ==="
  aws lambda get-function \
    --function-name AcidoSecrets \
    --region $REGION \
    --query 'Configuration.[FunctionName,State,LastModified]' \
    --output table
done
```

### Check Azure Key Vaults

```bash
VAULTS=("kv-secrets-westeurope" "kv-secrets-germanywestcentral" "kv-secrets-eastus" "kv-secrets-westus2" "kv-secrets-southeastasia" "kv-secrets-japaneast")

for VAULT in "${VAULTS[@]}"; do
  echo "=== $VAULT ==="
  az keyvault show --name $VAULT --query '[name,location,properties.vaultUri]' --output table
done
```

### Test Deployment

1. Push a commit to the `main` branch
2. Check GitHub Actions workflow: `Actions` → `Deploy Secrets Lambda to AWS (Multi-Region)`
3. Monitor deployment progress for all 6 regions
4. Verify health checks pass for each region

## Step 5: Get Lambda Function URLs

After successful deployment, retrieve the function URLs:

```bash
REGIONS=("eu-west-1" "eu-central-1" "us-east-1" "us-west-2" "ap-southeast-1" "ap-northeast-1")

echo "Lambda Function URLs:"
echo "{"
for REGION in "${REGIONS[@]}"; do
  URL=$(aws lambda get-function-url-config \
    --function-name AcidoSecrets \
    --region $REGION \
    --query 'FunctionUrl' \
    --output text 2>/dev/null || echo "not_configured")
  echo "  '$REGION': '$URL',"
done
echo "}"
```

Copy these URLs and create a region dictionary in your frontend application.

## Troubleshooting

### Deployment Fails for Specific Region

1. Check if Lambda function exists in that region
2. Verify region-specific Azure secrets are set correctly
3. Check Azure Key Vault permissions for the Service Principal
4. Review workflow logs in GitHub Actions

### Azure Key Vault Access Denied

```bash
# Verify Service Principal has correct permissions
az keyvault show-policy --name YOUR_VAULT_NAME --spn YOUR_CLIENT_ID
```

### Missing GitHub Secrets

The workflow will fail if any required secret is missing. Check the workflow logs to identify which secret is missing.

## Cost Optimization

- **ECR**: One repository in eu-west-1 (minimal cost)
- **Lambda**: Pay per request per region (no idle cost with Function URLs)
- **Azure Key Vault**: Per operation pricing (very low for typical usage)
- **Data Transfer**: Consider same-region traffic between Lambda and Key Vault where possible

## Security Best Practices

1. ✅ Use separate Service Principals per Key Vault (Option A) for better isolation
2. ✅ Rotate Service Principal secrets regularly
3. ✅ Enable Azure Key Vault logging and monitoring
4. ✅ Use AWS IAM roles with least privilege
5. ✅ Enable CloudFlare Turnstile bot protection (`CF_SECRET_KEY`)
6. ✅ Review Lambda execution logs regularly
7. ✅ Set up alerts for failed deployments

## Next Steps

1. Configure frontend to use the region endpoints dictionary
2. Implement region selection logic (geo-based or user choice)
3. Set up monitoring and alerting for all regions
4. Configure backup and disaster recovery procedures
5. Document region-specific incident response procedures

## Support

For issues or questions:
- Check workflow logs in GitHub Actions
- Review Lambda CloudWatch logs
- Verify Azure Key Vault access logs
- Open an issue in the repository

---

**Last Updated**: 2025-11-06
