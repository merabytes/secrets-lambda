#!/usr/bin/env bash
###############################################################################
# setup-azure-teardown.sh
#
# Tears down all Azure Key Vault resources created by setup-azure-credentials.sh
# This script removes resources from all specified regions.
#
# Resources removed per region:
#   - Key Vault
#   - Service Principal
#   - Resource Group (if it only contains resources from this project)
#
# This script uses uninstall.sh internally for each Azure region.
#
# Usage:
#   ./setup-azure-teardown.sh --azure-subscription YOUR_SUB_ID
#
# Options:
#   --azure-subscription ID       Azure subscription ID (required)
#   --project-name NAME           Project name prefix (default: merabytes)
#   --azure-regions REGION1,REGION2 Comma-separated Azure regions (default: all)
#   --delete-resource-groups      Delete resource groups (use with caution)
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
DELETE_RG=false
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
    ["switzerlandnorth"]="Switzerland North (Zurich)"
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
    ["jioindiawest"]="Jio India West"
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

Tears down Azure Key Vault resources created by setup-azure-credentials.sh
across all specified regions.

Options:
    --azure-subscription ID       Azure subscription ID (required)
    --project-name NAME           Project name prefix (default: $PROJECT_NAME)
    --azure-regions REGION1,REGION2 Comma-separated Azure regions (default: all)
    --delete-resource-groups      Delete resource groups (use with extreme caution)
    --dry-run                     Show what would be done
    -h, --help                    Show this help

Examples:
    # Teardown all Azure regions (keeps resource groups)
    $0 --azure-subscription abc-123-def-456

    # Teardown specific regions
    $0 --azure-subscription abc-123 --azure-regions eastus,westeurope,southeastasia

    # Teardown and delete resource groups (DANGEROUS!)
    $0 --azure-subscription abc-123 --delete-resource-groups

    # Dry run to see what would be deleted
    $0 --azure-subscription abc-123 --dry-run
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
            --azure-regions) IFS=',' read -ra AZURE_REGIONS_FILTER <<< "$2"; shift 2 ;;
            --delete-resource-groups) DELETE_RG=true; shift ;;
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
    
    # Check if uninstall.sh exists
    if [[ ! -f "$SCRIPT_DIR/../uninstall.sh" ]]; then
        die "uninstall.sh not found at $SCRIPT_DIR/../uninstall.sh"
    fi
}

###############################################################################
# Teardown Azure Key Vault for a region
###############################################################################
teardown_azure_region() {
    local azure_region="$1"
    local region_name="${AZURE_REGIONS_MAP[$azure_region]:-$azure_region}"
    
    info "=========================================="
    info "Tearing down Azure region: $azure_region ($region_name)"
    info "=========================================="
    
    if $DRY_RUN; then
        note "[DRY-RUN] Would teardown Azure in $azure_region"
        return
    fi
    
    # Generate resource names (must match setup script)
    local resource_group="${PROJECT_NAME}${azure_region}"
    local kv_name="${PROJECT_NAME}${azure_region}"
    local sp_name="${PROJECT_NAME}-${azure_region}"
    
    # Truncate Key Vault name if too long (max 24 chars)
    if [[ ${#kv_name} -gt 24 ]]; then
        kv_name="${kv_name:0:24}"
    fi
    
    # Check if resource group exists
    local rg_exists
    rg_exists="$(az group exists --name "$resource_group" 2>/dev/null || echo "false")"
    
    if [[ "$rg_exists" == "false" ]]; then
        warn "Resource group '$resource_group' does not exist. Skipping region."
        # Still try to delete Service Principal as it may exist without RG
        delete_service_principal_only "$sp_name"
        return
    fi
    
    # Build uninstall.sh command
    local uninstall_cmd=(
        bash "$SCRIPT_DIR/../uninstall.sh"
        --subscription-id "$AZURE_SUBSCRIPTION_ID"
        --resource-group "$resource_group"
        --sp-name "$sp_name"
        --kv "$kv_name"
    )
    
    if $DELETE_RG; then
        uninstall_cmd+=(--delete-rg)
    fi
    
    # Execute uninstall
    info "Executing: ${uninstall_cmd[*]}"
    if "${uninstall_cmd[@]}"; then
        info "Successfully tore down $azure_region"
    else
        warn "Failed to teardown $azure_region (continuing with other regions)"
    fi
}

###############################################################################
# Delete Service Principal only (when RG doesn't exist)
###############################################################################
delete_service_principal_only() {
    local sp_name="$1"
    
    info "Checking for orphaned Service Principal '$sp_name'..."
    local app_id
    app_id="$(az ad sp list --display-name "$sp_name" --query '[0].appId' -o tsv 2>/dev/null || true)"
    
    if [[ -z "$app_id" || "$app_id" == "null" ]]; then
        return
    fi
    
    info "Deleting Service Principal '$sp_name' (appId: $app_id)..."
    az ad sp delete --id "$app_id" 2>/dev/null || warn "Failed to delete Service Principal"
}

###############################################################################
# Get regions to process
###############################################################################
get_regions_to_process() {
    local regions=()
    
    if [[ ${#AZURE_REGIONS_FILTER[@]} -gt 0 ]]; then
        # Use filtered regions
        for region in "${AZURE_REGIONS_FILTER[@]}"; do
            if [[ -n "${AZURE_REGIONS_MAP[$region]:-}" ]]; then
                regions+=("$region")
            else
                warn "Unknown Azure region: $region (skipping)"
            fi
        done
    else
        # Use all regions
        for region in "${!AZURE_REGIONS_MAP[@]}"; do
            regions+=("$region")
        done
    fi
    
    # Sort regions for consistent output
    IFS=$'\n' sorted=($(sort <<<"${regions[*]}"))
    unset IFS
    
    printf "%s\n" "${sorted[@]}"
}

###############################################################################
# Main
###############################################################################
main() {
    parse_args "$@"
    validate_prerequisites
    
    # Set Azure subscription
    az account set --subscription "$AZURE_SUBSCRIPTION_ID"
    info "Using Azure subscription: $AZURE_SUBSCRIPTION_ID"
    
    # Get regions to process
    mapfile -t regions_to_process < <(get_regions_to_process)
    
    if [[ ${#regions_to_process[@]} -eq 0 ]]; then
        die "No Azure regions to process"
    fi
    
    info "=========================================="
    info "Azure Teardown Configuration"
    info "=========================================="
    info "Project name: $PROJECT_NAME"
    info "Regions to teardown: ${#regions_to_process[@]}"
    info "Delete resource groups: $DELETE_RG"
    info "Dry run: $DRY_RUN"
    info "=========================================="
    
    if $DELETE_RG && ! $DRY_RUN; then
        warn ""
        warn "WARNING: Resource group deletion is enabled!"
        warn "This will permanently delete ALL resources in each region's resource group!"
        warn ""
        warn "Waiting 10 seconds... Press Ctrl+C to cancel."
        sleep 10
    fi
    
    # Track results
    local success_count=0
    local fail_count=0
    
    # Process each region
    for region in "${regions_to_process[@]}"; do
        if teardown_azure_region "$region"; then
            ((success_count++)) || true
        else
            ((fail_count++)) || true
        fi
        echo ""  # Blank line between regions
    done
    
    # Summary
    info "=========================================="
    info "Teardown Summary"
    info "=========================================="
    info "Total regions processed: ${#regions_to_process[@]}"
    info "Successful: $success_count"
    if [[ $fail_count -gt 0 ]]; then
        warn "Failed: $fail_count"
    fi
    
    if $DRY_RUN; then
        note "This was a dry run. No resources were deleted."
    else
        info "Teardown complete!"
        if $DELETE_RG; then
            warn "Resource group deletions may still be running in the background."
            warn "Check Azure Portal to verify completion."
        fi
    fi
    info "=========================================="
}

main "$@"
