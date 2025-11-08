#!/bin/bash

# Multi-Region Deployment Validation Script
# This script helps validate that all prerequisites are in place for multi-region deployment

set -e

echo "=================================================="
echo "Multi-Region Deployment Validation"
echo "=================================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Function to check AWS CLI
check_aws_cli() {
    echo "Checking AWS CLI..."
    if command -v aws &> /dev/null; then
        AWS_VERSION=$(aws --version 2>&1 | cut -d' ' -f1)
        echo -e "${GREEN}✓${NC} AWS CLI is installed: $AWS_VERSION"
        ((PASSED++))
    else
        echo -e "${RED}✗${NC} AWS CLI is not installed"
        ((FAILED++))
    fi
    echo ""
}

# Function to check Azure CLI
check_azure_cli() {
    echo "Checking Azure CLI..."
    if command -v az &> /dev/null; then
        # Try to get version - fallback if jq is not available
        if command -v jq &> /dev/null; then
            AZURE_VERSION=$(az version --output json 2>/dev/null | jq -r '."azure-cli"' || echo "installed")
        else
            AZURE_VERSION=$(az version 2>&1 | grep -o '"azure-cli": "[^"]*"' | cut -d'"' -f4 || echo "installed")
        fi
        echo -e "${GREEN}✓${NC} Azure CLI is installed: $AZURE_VERSION"
        ((PASSED++))
    else
        echo -e "${RED}✗${NC} Azure CLI is not installed"
        ((FAILED++))
    fi
    echo ""
}

# Function to check AWS credentials
check_aws_credentials() {
    echo "Checking AWS credentials..."
    if aws sts get-caller-identity &> /dev/null; then
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
        echo -e "${GREEN}✓${NC} AWS credentials are valid"
        echo "  Account ID: $ACCOUNT_ID"
        echo "  User/Role: $USER_ARN"
        ((PASSED++))
    else
        echo -e "${RED}✗${NC} AWS credentials are not configured or invalid"
        ((FAILED++))
    fi
    echo ""
}

# Function to check Azure credentials
check_azure_credentials() {
    echo "Checking Azure credentials..."
    if az account show &> /dev/null; then
        SUBSCRIPTION_NAME=$(az account show --query name --output tsv)
        SUBSCRIPTION_ID=$(az account show --query id --output tsv)
        echo -e "${GREEN}✓${NC} Azure credentials are valid"
        echo "  Subscription: $SUBSCRIPTION_NAME"
        echo "  Subscription ID: $SUBSCRIPTION_ID"
        ((PASSED++))
    else
        echo -e "${RED}✗${NC} Azure credentials are not configured"
        echo "  Run: az login"
        ((FAILED++))
    fi
    echo ""
}

# Function to check ECR repository
check_ecr_repository() {
    echo "Checking ECR repository (acido-secrets in eu-west-1)..."
    if aws ecr describe-repositories --repository-names acido-secrets --region eu-west-1 &> /dev/null; then
        ECR_URI=$(aws ecr describe-repositories --repository-names acido-secrets --region eu-west-1 --query 'repositories[0].repositoryUri' --output text)
        echo -e "${GREEN}✓${NC} ECR repository exists: $ECR_URI"
        ((PASSED++))
    else
        echo -e "${RED}✗${NC} ECR repository 'acido-secrets' not found in eu-west-1"
        echo "  Create with: aws ecr create-repository --repository-name acido-secrets --region eu-west-1"
        ((FAILED++))
    fi
    echo ""
}

# Function to check Lambda functions in all regions
check_lambda_functions() {
    echo "Checking Lambda functions in all regions..."
    REGIONS=("eu-west-1" "eu-central-1" "us-east-1" "us-west-2" "ap-southeast-1" "ap-northeast-1")
    LAMBDA_FOUND=0
    
    for REGION in "${REGIONS[@]}"; do
        if aws lambda get-function --function-name AcidoSecrets --region $REGION &> /dev/null; then
            echo -e "${GREEN}✓${NC} Lambda 'AcidoSecrets' exists in $REGION"
            ((LAMBDA_FOUND++))
            
            # Check if Function URL is configured
            if aws lambda get-function-url-config --function-name AcidoSecrets --region $REGION &> /dev/null 2>&1; then
                FUNC_URL=$(aws lambda get-function-url-config --function-name AcidoSecrets --region $REGION --query 'FunctionUrl' --output text)
                echo "  Function URL: $FUNC_URL"
            else
                echo -e "  ${YELLOW}⚠${NC} Function URL not configured (optional)"
                ((WARNINGS++))
            fi
        else
            echo -e "${RED}✗${NC} Lambda 'AcidoSecrets' not found in $REGION"
            ((FAILED++))
        fi
    done
    
    if [ $LAMBDA_FOUND -eq 6 ]; then
        echo -e "${GREEN}✓${NC} All Lambda functions exist (6/6)"
        ((PASSED++))
    else
        echo -e "${RED}✗${NC} Only $LAMBDA_FOUND/6 Lambda functions exist"
    fi
    echo ""
}

# Function to check Azure Key Vaults
check_azure_key_vaults() {
    echo "Checking Azure Key Vaults..."
    VAULTS=("kv-secrets-westeurope" "kv-secrets-germanywestcentral" "kv-secrets-eastus" "kv-secrets-westus2" "kv-secrets-southeastasia" "kv-secrets-japaneast")
    VAULTS_FOUND=0
    
    for VAULT in "${VAULTS[@]}"; do
        if az keyvault show --name $VAULT &> /dev/null 2>&1; then
            VAULT_LOCATION=$(az keyvault show --name $VAULT --query location --output tsv)
            echo -e "${GREEN}✓${NC} Key Vault '$VAULT' exists in $VAULT_LOCATION"
            ((VAULTS_FOUND++))
        else
            echo -e "${RED}✗${NC} Key Vault '$VAULT' not found"
            ((FAILED++))
        fi
    done
    
    if [ $VAULTS_FOUND -eq 6 ]; then
        echo -e "${GREEN}✓${NC} All Key Vaults exist (6/6)"
        ((PASSED++))
    else
        echo -e "${RED}✗${NC} Only $VAULTS_FOUND/6 Key Vaults exist"
    fi
    echo ""
}

# Function to validate GitHub secrets structure
check_github_secrets_info() {
    echo "GitHub Secrets Checklist:"
    echo "The following secrets must be configured in GitHub repository settings:"
    echo ""
    echo "Global Secrets (Required):"
    echo "  - AWS_ACCESS_KEY_ID"
    echo "  - AWS_SECRET_ACCESS_KEY"
    echo "  - ECR_REGISTRY"
    echo ""
    echo "Global Secrets (Optional):"
    echo "  - CORS_ORIGIN"
    echo "  - CF_SECRET_KEY"
    echo ""
    echo "Region-Specific Secrets (24 total):"
    REGIONS_CODES=("WESTEUROPE" "GERMANYWESTCENTRAL" "EASTUS" "WESTUS2" "SOUTHEASTASIA" "JAPANEAST")
    for CODE in "${REGIONS_CODES[@]}"; do
        echo "  - ${CODE}_AZURE_TENANT_ID"
        echo "  - ${CODE}_AZURE_CLIENT_ID"
        echo "  - ${CODE}_AZURE_CLIENT_SECRET"
        echo "  - ${CODE}_AZURE_KEY_VAULT_NAME"
    done
    echo ""
    echo -e "${YELLOW}⚠${NC} GitHub secrets cannot be validated from this script."
    echo "  Please verify manually in: GitHub Repository → Settings → Secrets and variables → Actions"
    ((WARNINGS++))
    echo ""
}

# Function to print summary
print_summary() {
    echo "=================================================="
    echo "Validation Summary"
    echo "=================================================="
    echo -e "${GREEN}Passed:${NC} $PASSED"
    echo -e "${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "${RED}Failed:${NC} $FAILED"
    echo ""
    
    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All critical checks passed!${NC}"
        echo "You can proceed with multi-region deployment."
    else
        echo -e "${RED}✗ Some checks failed.${NC}"
        echo "Please fix the issues above before deploying."
        exit 1
    fi
    echo "=================================================="
}

# Main execution
main() {
    check_aws_cli
    check_azure_cli
    check_aws_credentials
    check_azure_credentials
    check_ecr_repository
    check_lambda_functions
    check_azure_key_vaults
    check_github_secrets_info
    print_summary
}

# Run main function
main
