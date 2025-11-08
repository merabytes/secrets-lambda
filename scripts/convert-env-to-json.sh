#!/usr/bin/env bash
#
# Convert azure-credentials.env to JSON format for AZURE_REGION_CONFIGS secret
#
# Usage:
#   ./scripts/convert-env-to-json.sh azure-credentials.env
#
# Output:
#   JSON object with region configurations suitable for GitHub Secrets
#

set -Eeuo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Functions for colored output
error() { echo -e "${RED}✗ Error: $*${NC}" >&2; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${BLUE}ℹ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }

show_help() {
  cat << EOF
Convert Azure credentials env file to JSON format

Usage:
  $(basename "$0") <env-file>

Arguments:
  env-file    Path to azure-credentials.env file

Example:
  $(basename "$0") azure-credentials.env > azure-config.json

Output Format:
  {
    "REGIONCODE": {
      "AZURE_TENANT_ID": "xxx",
      "AZURE_CLIENT_ID": "xxx",
      "AZURE_CLIENT_SECRET": "xxx",
      "AZURE_KEY_VAULT_NAME": "xxx"
    },
    ...
  }

The output JSON can be stored as the AZURE_REGION_CONFIGS GitHub Secret.

EOF
}

# Parse arguments
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  show_help
  exit 0
fi

ENV_FILE="$1"

# Validate input file
if [ ! -f "$ENV_FILE" ]; then
  error "File not found: $ENV_FILE"
  exit 1
fi

info "Converting $ENV_FILE to JSON format..."
echo ""

# Initialize JSON object
echo "{"

# Track if we've printed the first entry (for comma handling)
first_entry=true

# Temporary variables to accumulate region data
current_region=""
tenant_id=""
client_id=""
client_secret=""
key_vault_name=""

# Process the env file line by line
while IFS= read -r line || [ -n "$line" ]; do
  # Skip empty lines and comments
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  
  # Remove 'export ' prefix if present
  line="${line#export }"
  
  # Parse the variable name and value
  if [[ "$line" =~ ^([A-Z_]+)=\"?([^\"]*)\"?$ ]] || [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
    var_name="${BASH_REMATCH[1]}"
    var_value="${BASH_REMATCH[2]}"
    
    # Remove trailing quote if present
    var_value="${var_value%\"}"
    
    # Extract region code from variable name (e.g., EASTUS_AZURE_TENANT_ID -> EASTUS)
    if [[ "$var_name" =~ ^([A-Z]+)_AZURE_(.+)$ ]]; then
      region_code="${BASH_REMATCH[1]}"
      field_name="${BASH_REMATCH[2]}"
      
      # If we're starting a new region, output the previous one
      if [ -n "$current_region" ] && [ "$region_code" != "$current_region" ]; then
        # Print the accumulated region data
        if [ "$first_entry" = true ]; then
          first_entry=false
        else
          echo ","
        fi
        
        echo "  \"$current_region\": {"
        echo "    \"AZURE_TENANT_ID\": \"$tenant_id\","
        echo "    \"AZURE_CLIENT_ID\": \"$client_id\","
        echo "    \"AZURE_CLIENT_SECRET\": \"$client_secret\","
        echo "    \"AZURE_KEY_VAULT_NAME\": \"$key_vault_name\""
        echo -n "  }"
        
        # Reset for new region
        tenant_id=""
        client_id=""
        client_secret=""
        key_vault_name=""
      fi
      
      # Update current region
      current_region="$region_code"
      
      # Store the field value
      case "$field_name" in
        TENANT_ID)
          tenant_id="$var_value"
          ;;
        CLIENT_ID)
          client_id="$var_value"
          ;;
        CLIENT_SECRET)
          client_secret="$var_value"
          ;;
        KEY_VAULT_NAME)
          key_vault_name="$var_value"
          ;;
      esac
    fi
  fi
done < "$ENV_FILE"

# Output the last region
if [ -n "$current_region" ]; then
  if [ "$first_entry" = true ]; then
    first_entry=false
  else
    echo ","
  fi
  
  echo "  \"$current_region\": {"
  echo "    \"AZURE_TENANT_ID\": \"$tenant_id\","
  echo "    \"AZURE_CLIENT_ID\": \"$client_id\","
  echo "    \"AZURE_CLIENT_SECRET\": \"$client_secret\","
  echo "    \"AZURE_KEY_VAULT_NAME\": \"$key_vault_name\""
  echo -n "  }"
fi

echo ""
echo "}"

info "" >&2
success "Conversion complete!" >&2
info "Copy the JSON output above and store it as the AZURE_REGION_CONFIGS GitHub Secret" >&2
