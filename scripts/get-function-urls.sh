#!/bin/bash

# Script to retrieve Lambda Function URLs from all regions
# This creates a dictionary that can be used in frontend applications

echo "=================================================="
echo "Lambda Function URLs for All Regions"
echo "=================================================="
echo ""

REGIONS=("eu-west-1" "eu-central-1" "us-east-1" "us-west-2" "ap-southeast-1" "ap-northeast-1")
FUNCTION_NAME="AcidoSecrets"

echo "Retrieving Lambda Function URLs..."
echo ""

# Retrieve URLs once and store in associative array
declare -A URLS
for REGION in "${REGIONS[@]}"; do
    URL=$(aws lambda get-function-url-config \
        --function-name $FUNCTION_NAME \
        --region $REGION \
        --query 'FunctionUrl' \
        --output text 2>/dev/null || echo "NOT_CONFIGURED")
    URLS[$REGION]=$URL
done

# Function to print in JSON format
print_json() {
    echo "JSON Format:"
    echo "{"
    local first=true
    for REGION in "${REGIONS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo -n "  \"$REGION\": \"${URLS[$REGION]}\""
    done
    echo ""
    echo "}"
    echo ""
}

# Function to print in JavaScript format
print_javascript() {
    echo "JavaScript Format:"
    echo "const REGION_ENDPOINTS = {"
    local first=true
    for REGION in "${REGIONS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo -n "  '$REGION': '${URLS[$REGION]}'"
    done
    echo ""
    echo "};"
    echo ""
}

# Function to print in Python format
print_python() {
    echo "Python Format:"
    echo "REGION_ENDPOINTS = {"
    local first=true
    for REGION in "${REGIONS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo -n "    '$REGION': '${URLS[$REGION]}'"
    done
    echo ""
    echo "}"
    echo ""
}

# Function to print in table format
print_table() {
    echo "Table Format:"
    echo "+-----------------+--------------------------------------------------------+"
    printf "| %-15s | %-54s |\n" "Region" "Function URL"
    echo "+-----------------+--------------------------------------------------------+"
    for REGION in "${REGIONS[@]}"; do
        printf "| %-15s | %-54s |\n" "$REGION" "${URLS[$REGION]}"
    done
    echo "+-----------------+--------------------------------------------------------+"
    echo ""
}

# Print all formats
print_json
print_javascript
print_python
print_table

echo "=================================================="
echo "Copy the format you need for your frontend application"
echo "=================================================="
