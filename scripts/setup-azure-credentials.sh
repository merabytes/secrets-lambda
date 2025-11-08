#!/usr/bin/env bash
###############################################################################
# setup-azure-credentials.sh
#
# Generates Azure Key Vault credentials for all specified regions.
# This script is designed to be run once in Azure Cloud Shell.
#
# Output: A single consolidated .env file with all Azure credentials
# Format: {REGION}_AZURE_TENANT_ID, {REGION}_AZURE_CLIENT_ID, etc.
#
# This script uses install.sh internally for each Azure region.
#
# Usage:
#   ./setup-azure-credentials.sh --azure-subscription YOUR_SUB_ID
#
# Options:
#   --azure-subscription ID       Azure subscription ID (required)
#   --project-name NAME           Project name prefix (default: merabytes)
#   --output-file FILE            Output credentials file (default: azure-credentials.env)
#   --azure-regions REGION1,REGION2 Comma-separated Azure regions (default: all)
#   --dry-run                     Show what would be done without executing
#   -h, --help                    Show this help
###############################################################################

set -Eeuo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Configuration
###############################################################################
AZURE_SUBSCRIPTION_ID=""
PROJECT_NAME="merabytes"
OUTPUT_FILE="azure-credentials.env"
DRY_RUN=false
AZURE_REGIONS_FILTER=()  # Initialize empty array

# Colors
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'
C_RESET=$'\033[0m'

###############################################################################
# Logging
###############################################################################
info()  { printf "${C_GREEN}[INFO]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*"; }
error() { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; }
note()  { printf "${C_BLUE}[NOTE]${C_RESET} %s\n" "$*"; }
die()   { error "$*"; exit 1; }

###############################################################################
# Azure regions - Only using regions available for resource group creation
# Source: az account list-locations --query "[?metadata.regionCategory=='Recommended'].name"
###############################################################################
declare -A AZURE_REGIONS_MAP=(
    # US Regions
    ["eastus"]="East US"
    ["eastus2"]="East US 2"
    ["westus"]="West US"
    ["westus2"]="West US 2"
    ["westus3"]="West US 3"
    ["centralus"]="Central US"
    ["northcentralus"]="North Central US"
    ["southcentralus"]="South Central US"
    ["westcentralus"]="West Central US"
    # Europe Regions
    ["northeurope"]="North Europe (Ireland)"
    ["westeurope"]="West Europe (Netherlands)"
    ["uksouth"]="UK South (London)"
    ["ukwest"]="UK West (Cardiff)"
    ["francecentral"]="France Central (Paris)"
    ["germanywestcentral"]="Germany West Central (Frankfurt)"
    ["norwayeast"]="Norway East"
    ["swedencentral"]="Sweden Central"
    ["italynorth"]="Italy North (Milan)"
    ["spaincentral"]="Spain Central (Madrid)"
    ["polandcentral"]="Poland Central (Warsaw)"
    ["austriaeast"]="Austria East (Vienna)"
    ["belgiumcentral"]="Belgium Central (Brussels)"
    # Asia Pacific Regions
    ["southeastasia"]="Southeast Asia (Singapore)"
    ["eastasia"]="East Asia (Hong Kong)"
    ["japaneast"]="Japan East (Tokyo)"
    ["japanwest"]="Japan West (Osaka)"
    ["koreacentral"]="Korea Central (Seoul)"
    ["koreasouth"]="Korea South (Busan)"
    ["centralindia"]="Central India (Pune)"
    ["southindia"]="South India (Chennai)"
    ["westindia"]="West India (Mumbai)"
    ["australiaeast"]="Australia East"
    ["australiasoutheast"]="Australia Southeast"
    ["australiacentral"]="Australia Central"
    ["indonesiacentral"]="Indonesia Central (Jakarta)"
    ["malaysiawest"]="Malaysia West (Kuala Lumpur)"
    ["newzealandnorth"]="New Zealand North (Auckland)"
    # Americas (Non-US)
    ["brazilsouth"]="Brazil South (São Paulo)"
    ["canadacentral"]="Canada Central (Toronto)"
    ["canadaeast"]="Canada East (Quebec)"
    ["chilecentral"]="Chile Central (Santiago)"
    ["mexicocentral"]="Mexico Central (Querétaro)"
    # Middle East & Africa
    ["southafricanorth"]="South Africa North (Johannesburg)"
    ["qatarcentral"]="Qatar Central (Doha)"
    ["uaenorth"]="UAE North (Dubai)"
    ["israelcentral"]="Israel Central"
)

###############################################################################
# Usage
###############################################################################
usage() {
    cat <<EOF
Usage: $0 [options]

Generates Azure Key Vault credentials for all specified regions.
Outputs a single consolidated .env file for GitHub Secrets configuration.

Options:
    --azure-subscription ID       Azure subscription ID (required)
    --project-name NAME           Project name prefix (default: $PROJECT_NAME)
    --output-file FILE            Output credentials file (default: $OUTPUT_FILE)
    --azure-regions REGION1,REGION2 Comma-separated Azure regions (default: all)
    --dry-run                     Show what would be done
    -h, --help                    Show this help

Examples:
    # Generate credentials for all Azure regions
    $0 --azure-subscription abc-123-def-456

    # Generate credentials for specific regions
    $0 --azure-subscription abc-123 --azure-regions eastus,westeurope,southeastasia

    # Custom output file
    $0 --azure-subscription abc-123 --output-file my-azure-creds.env
EOF
}

###############################################################################
# Parse arguments
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --azure-subscription) AZURE_SUBSCRIPTION_ID="$2"; shift 2 ;;
            --project-name) PROJECT_NAME="$2"; shift 2 ;;
            --output-file) OUTPUT_FILE="$2"; shift 2 ;;
            --azure-regions) IFS=',' read -ra AZURE_REGIONS_FILTER <<< "$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

###############################################################################
# Validate prerequisites
###############################################################################
validate_prerequisites() {
    command -v az >/dev/null 2>&1 || die "Azure CLI not found. Install it first."
    [[ -z "$AZURE_SUBSCRIPTION_ID" ]] && die "Azure subscription ID required. Use --azure-subscription"
    az account show >/dev/null 2>&1 || die "Azure CLI not logged in. Run: az login"
    
    # Check if install.sh exists
    if [[ ! -f "$SCRIPT_DIR/../install.sh" ]]; then
        die "install.sh not found at $SCRIPT_DIR/../install.sh"
    fi
}

###############################################################################
# Setup Azure Key Vault for a region
###############################################################################
setup_azure_region() {
    local azure_region="$1"
    local region_name="${AZURE_REGIONS_MAP[$azure_region]:-$azure_region}"
    
    info "=========================================="
    info "Setting up Azure region: $azure_region ($region_name)"
    info "=========================================="
    
    if $DRY_RUN; then
        note "[DRY-RUN] Would setup Azure in $azure_region"
        return
    fi
    
    # Generate resource names
    local resource_group="${PROJECT_NAME}${azure_region}"
    local kv_name="${PROJECT_NAME}${azure_region}"
    local sp_name="${PROJECT_NAME}-${azure_region}"
    local temp_env_file="/tmp/${azure_region}.env"
    
    # Truncate Key Vault name if too long (max 24 chars)
    if [[ ${#kv_name} -gt 24 ]]; then
        kv_name="${kv_name:0:24}"
    fi
    
    info "Resource Group: $resource_group"
    info "Key Vault: $kv_name"
    info "Service Principal: $sp_name"
    
    # Call install.sh for this region
    "$SCRIPT_DIR/../install.sh" \
        --subscription-id "$AZURE_SUBSCRIPTION_ID" \
        --resource-group "$resource_group" \
        --location "$azure_region" \
        --sp-name "$sp_name" \
        --kv "$kv_name" \
        --emit-env-file "$temp_env_file" \
        --create-rg \
        --show-secret
    
    if [[ -f "$temp_env_file" ]]; then
        info "Environment file created: $temp_env_file"
        
        # Extract credentials and append to output file
        local region_upper=$(echo "$azure_region" | tr '[:lower:]' '[:upper:]')
        
        # Extract values from temp env file
        local tenant_id=$(grep "^export AZURE_TENANT_ID=" "$temp_env_file" | cut -d'"' -f2)
        local client_id=$(grep "^export AZURE_CLIENT_ID=" "$temp_env_file" | cut -d'"' -f2)
        local client_secret=$(grep "^export AZURE_CLIENT_SECRET=" "$temp_env_file" | cut -d'"' -f2)
        local key_vault_name=$(grep "^export KEY_VAULT_NAME=" "$temp_env_file" | cut -d'"' -f2)
        
        # Append to consolidated file
        {
            echo "# Region: $azure_region ($region_name)"
            echo "export ${region_upper}_AZURE_TENANT_ID=\"$tenant_id\""
            echo "export ${region_upper}_AZURE_CLIENT_ID=\"$client_id\""
            echo "export ${region_upper}_AZURE_CLIENT_SECRET=\"$client_secret\""
            echo "export ${region_upper}_AZURE_KEY_VAULT_NAME=\"$key_vault_name\""
            echo ""
        } >> "$OUTPUT_FILE"
        
        # Clean up temp file
        rm -f "$temp_env_file"
        
        info "Credentials appended to $OUTPUT_FILE"
    else
        warn "Environment file not created for $azure_region"
    fi
}

###############################################################################
# Generate Azure credentials for all regions
###############################################################################
generate_azure_credentials() {
    info "=========================================="
    info "Generating Azure Key Vault Credentials"
    info "=========================================="
    
    # Initialize output file
    {
        echo "# Azure Key Vault Credentials for All Regions"
        echo "# Generated: $(date)"
        echo "# Project: $PROJECT_NAME"
        echo ""
        echo "# These credentials should be added to GitHub Secrets"
        echo "# Format: {REGION}_AZURE_TENANT_ID, {REGION}_AZURE_CLIENT_ID, etc."
        echo ""
    } > "$OUTPUT_FILE"
    
    # Determine regions to setup
    local regions_to_setup=()
    if [[ ${#AZURE_REGIONS_FILTER[@]} -gt 0 ]]; then
        regions_to_setup=("${AZURE_REGIONS_FILTER[@]}")
    else
        # Use all Azure regions
        regions_to_setup=("${!AZURE_REGIONS_MAP[@]}")
    fi
    
    # Setup each Azure region
    for azure_region in "${regions_to_setup[@]}"; do
        setup_azure_region "$azure_region"
    done
    
    info "=========================================="
    info "Azure credentials generation complete!"
    info "=========================================="
    info "Output file: $OUTPUT_FILE"
    info ""
    note "Next steps:"
    note "1. Review the credentials in: $OUTPUT_FILE"
    note "2. Add each {REGION}_AZURE_* variable to GitHub Secrets"
    note "3. Run the deploy workflow to create/update Lambda functions"
}

###############################################################################
# Main
###############################################################################
main() {
    parse_args "$@"
    validate_prerequisites
    
    info "=========================================="
    info "Azure Credentials Setup"
    info "Project: $PROJECT_NAME"
    info "Output File: $OUTPUT_FILE"
    if $DRY_RUN; then
        warn "DRY RUN MODE - No changes will be made"
    fi
    info "=========================================="
    
    generate_azure_credentials
    
    info "=========================================="
    info "Setup Complete!"
    info "=========================================="
    note "Credentials saved to: $OUTPUT_FILE"
    note ""
    note "To configure GitHub Secrets, run:"
    note "  cat $OUTPUT_FILE"
    note ""
    note "Then add each {REGION}_AZURE_* variable to:"
    note "  GitHub Repository → Settings → Secrets and variables → Actions"
}

main "$@"
