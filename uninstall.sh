#!/usr/bin/env bash
###############################################################################
# uninstall.sh
#
# Teardown script for Azure resources created by install.sh
# This script removes:
#   - Key Vault (optional, if created)
#   - User Assigned Managed Identity (optional, if created)
#   - Storage Account (+ containers)
#   - Azure Container Registry (ACR)
#   - Service Principal
#   - Resource Group (optional, if --delete-rg is specified)
#
# Safe to run: checks for resource existence before deletion
#
# Usage:
#   ./uninstall.sh -s SUB_ID -g acido-rg -p acido -a acidocr -S acidostore123
#
# With Key Vault and Resource Group deletion:
#   ./uninstall.sh -s SUB -g acido-rg -p acido -a acidocr -S acidostore123 \
#     -k acidokv --delete-rg
###############################################################################
set -Eeuo pipefail

###############################################################################
# Configuration Defaults
###############################################################################
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
SP_NAME=""
ACR_NAME=""
STORAGE_ACCOUNT_NAME=""
IDENTITY_NAME=""
KV_NAME=""
DELETE_RG=false
DRY_RUN=false
COLOR=true

###############################################################################
# Color Handling
###############################################################################
if [[ ! -t 1 ]]; then COLOR=false; fi
if $COLOR; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_BLUE=$'\033[34m';  C_DIM=$'\033[2m';    C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_DIM=""; C_RESET=""
fi

###############################################################################
# Logging Helpers
###############################################################################
info()   { printf "%s[INFO]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()   { printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
note()   { printf "%s[NOTE]%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
dim()    { printf "%s[....]%s %s\n" "$C_DIM" "$C_RESET" "$*"; }
err()    { printf "%s[ERR ]%s %s\n"  "$C_RED" "$C_RESET" "$*" >&2; }
die()    { err "$*"; exit 1; }

###############################################################################
# Usage
###############################################################################
usage() {
  cat <<EOF
uninstall.sh - Remove Azure resources created by install.sh

Required:
  -s, --subscription-id ID          Azure Subscription ID
  -g, --resource-group NAME         Resource Group name
  -p, --sp-name NAME                Service Principal name

Optional:
  -a, --acr-name NAME               ACR name (if created)
  -S, --storage-account-name NAME   Storage Account name (if created)
  -i, --identity-name NAME          User Assigned Managed Identity name (if created)
  -k, --kv NAME                     Key Vault name (if created)
  --delete-rg                       Delete the entire resource group (use with caution)
  --dry-run                         Show what would be deleted without executing
  -h, --help                        Show this help

Examples:
  # Remove specific resources (keeps RG)
  ./uninstall.sh -s SUB_ID -g acido-rg -p acido -a acidocr -S acidostore123

  # Remove everything including resource group
  ./uninstall.sh -s SUB_ID -g acido-rg -p acido --delete-rg

  # Dry run to see what would be deleted
  ./uninstall.sh -s SUB_ID -g acido-rg -p acido -a acidocr --dry-run
EOF
}

###############################################################################
# Parse arguments
###############################################################################
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--subscription-id)      SUBSCRIPTION_ID="$2"; shift 2 ;;
      -g|--resource-group)       RESOURCE_GROUP="$2"; shift 2 ;;
      -p|--sp-name)              SP_NAME="$2"; shift 2 ;;
      -a|--acr-name)             ACR_NAME="$2"; shift 2 ;;
      -S|--storage-account-name) STORAGE_ACCOUNT_NAME="$2"; shift 2 ;;
      -i|--identity-name)        IDENTITY_NAME="$2"; shift 2 ;;
      -k|--kv)                   KV_NAME="$2"; shift 2 ;;
      --delete-rg)               DELETE_RG=true; shift ;;
      --dry-run)                 DRY_RUN=true; shift ;;
      -h|--help)                 usage; exit 0 ;;
      *) die "Unknown option: $1. Use -h for help." ;;
    esac
  done
}

###############################################################################
# Validate inputs
###############################################################################
validate_inputs() {
  [[ -z "$SUBSCRIPTION_ID" ]] && die "Missing --subscription-id"
  [[ -z "$RESOURCE_GROUP" ]]  && die "Missing --resource-group"
  [[ -z "$SP_NAME" ]]         && die "Missing --sp-name"
}

###############################################################################
# Ensure subscription
###############################################################################
ensure_subscription() {
  az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"
  az account set --subscription "$SUBSCRIPTION_ID"
  info "Using subscription: $SUBSCRIPTION_ID"
}

###############################################################################
# Check if resource group exists
###############################################################################
check_resource_group() {
  local exists
  exists="$(az group exists --name "$RESOURCE_GROUP")"
  if [[ "$exists" == "false" ]]; then
    warn "Resource group '$RESOURCE_GROUP' does not exist. Nothing to delete."
    exit 0
  fi
  info "Resource group '$RESOURCE_GROUP' exists."
}

###############################################################################
# Delete Key Vault
###############################################################################
delete_key_vault() {
  if [[ -z "$KV_NAME" ]]; then
    dim "No Key Vault specified, skipping."
    return
  fi
  
  info "Checking for Key Vault '$KV_NAME'..."
  local kv_exists
  kv_exists="$(az keyvault list --resource-group "$RESOURCE_GROUP" --query "[?name=='$KV_NAME'].name" -o tsv 2>/dev/null || true)"
  
  if [[ -z "$kv_exists" ]]; then
    dim "Key Vault '$KV_NAME' not found, skipping."
    return
  fi
  
  if $DRY_RUN; then
    note "[DRY-RUN] Would delete Key Vault: $KV_NAME"
    return
  fi
  
  info "Deleting Key Vault '$KV_NAME'..."
  az keyvault delete --name "$KV_NAME" --resource-group "$RESOURCE_GROUP" 2>/dev/null || warn "Failed to delete Key Vault"
  
  # Purge soft-deleted Key Vault
  info "Purging Key Vault '$KV_NAME' (removing from soft-delete)..."
  az keyvault purge --name "$KV_NAME" 2>/dev/null || warn "Failed to purge Key Vault (may not support purge or already purged)"
  
  info "Key Vault '$KV_NAME' deleted."
}

###############################################################################
# Delete Managed Identity
###############################################################################
delete_identity() {
  if [[ -z "$IDENTITY_NAME" ]]; then
    dim "No Managed Identity specified, skipping."
    return
  fi
  
  info "Checking for Managed Identity '$IDENTITY_NAME'..."
  local id_exists
  id_exists="$(az identity list --resource-group "$RESOURCE_GROUP" --query "[?name=='$IDENTITY_NAME'].name" -o tsv 2>/dev/null || true)"
  
  if [[ -z "$id_exists" ]]; then
    dim "Managed Identity '$IDENTITY_NAME' not found, skipping."
    return
  fi
  
  if $DRY_RUN; then
    note "[DRY-RUN] Would delete Managed Identity: $IDENTITY_NAME"
    return
  fi
  
  info "Deleting Managed Identity '$IDENTITY_NAME'..."
  az identity delete --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" 2>/dev/null || warn "Failed to delete Managed Identity"
  info "Managed Identity '$IDENTITY_NAME' deleted."
}

###############################################################################
# Delete Storage Account
###############################################################################
delete_storage_account() {
  if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
    dim "No Storage Account specified, skipping."
    return
  fi
  
  info "Checking for Storage Account '$STORAGE_ACCOUNT_NAME'..."
  local storage_exists
  storage_exists="$(az storage account list --resource-group "$RESOURCE_GROUP" --query "[?name=='$STORAGE_ACCOUNT_NAME'].name" -o tsv 2>/dev/null || true)"
  
  if [[ -z "$storage_exists" ]]; then
    dim "Storage Account '$STORAGE_ACCOUNT_NAME' not found, skipping."
    return
  fi
  
  if $DRY_RUN; then
    note "[DRY-RUN] Would delete Storage Account: $STORAGE_ACCOUNT_NAME"
    return
  fi
  
  info "Deleting Storage Account '$STORAGE_ACCOUNT_NAME'..."
  az storage account delete --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" --yes 2>/dev/null || warn "Failed to delete Storage Account"
  info "Storage Account '$STORAGE_ACCOUNT_NAME' deleted."
}

###############################################################################
# Delete ACR
###############################################################################
delete_acr() {
  if [[ -z "$ACR_NAME" ]]; then
    dim "No ACR specified, skipping."
    return
  fi
  
  info "Checking for ACR '$ACR_NAME'..."
  local acr_exists
  acr_exists="$(az acr list --resource-group "$RESOURCE_GROUP" --query "[?name=='$ACR_NAME'].name" -o tsv 2>/dev/null || true)"
  
  if [[ -z "$acr_exists" ]]; then
    dim "ACR '$ACR_NAME' not found, skipping."
    return
  fi
  
  if $DRY_RUN; then
    note "[DRY-RUN] Would delete ACR: $ACR_NAME"
    return
  fi
  
  info "Deleting ACR '$ACR_NAME'..."
  az acr delete --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --yes 2>/dev/null || warn "Failed to delete ACR"
  info "ACR '$ACR_NAME' deleted."
}

###############################################################################
# Delete Service Principal
###############################################################################
delete_service_principal() {
  info "Checking for Service Principal '$SP_NAME'..."
  local app_id
  app_id="$(az ad sp list --display-name "$SP_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)"
  
  if [[ -z "$app_id" || "$app_id" == "null" ]]; then
    dim "Service Principal '$SP_NAME' not found, skipping."
    return
  fi
  
  if $DRY_RUN; then
    note "[DRY-RUN] Would delete Service Principal: $SP_NAME (appId: $app_id)"
    return
  fi
  
  info "Deleting Service Principal '$SP_NAME' (appId: $app_id)..."
  az ad sp delete --id "$app_id" 2>/dev/null || warn "Failed to delete Service Principal"
  info "Service Principal '$SP_NAME' deleted."
}

###############################################################################
# Delete Resource Group
###############################################################################
delete_resource_group() {
  if ! $DELETE_RG; then
    info "Resource group deletion not requested (use --delete-rg to delete)."
    return
  fi
  
  if $DRY_RUN; then
    note "[DRY-RUN] Would delete Resource Group: $RESOURCE_GROUP"
    return
  fi
  
  warn "DELETING ENTIRE RESOURCE GROUP: $RESOURCE_GROUP"
  warn "This will remove ALL resources in the group!"
  info "Waiting 5 seconds... (Ctrl+C to cancel)"
  sleep 5
  
  info "Deleting Resource Group '$RESOURCE_GROUP'..."
  az group delete --name "$RESOURCE_GROUP" --yes --no-wait 2>/dev/null || warn "Failed to delete Resource Group"
  info "Resource Group '$RESOURCE_GROUP' deletion initiated (running in background)."
}

###############################################################################
# Main
###############################################################################
main() {
  parse_args "$@"
  validate_inputs
  ensure_subscription
  check_resource_group
  
  if $DRY_RUN; then
    warn "=== DRY RUN MODE - No changes will be made ==="
  fi
  
  info "=========================================="
  info "Starting teardown process"
  info "=========================================="
  
  # Delete resources in reverse order of dependencies
  delete_key_vault
  delete_identity
  delete_storage_account
  delete_acr
  delete_service_principal
  delete_resource_group
  
  info "=========================================="
  if $DRY_RUN; then
    info "Dry run complete. No resources were deleted."
  else
    info "Teardown complete!"
  fi
  info "=========================================="
}

main "$@"
