#!/bin/bash

# --- Configuration ---
# Enter the URL of your Immich instance here (without a trailing /)
IMMICH_URL="http://your-immich-url.local:2283"
# Enter your Immich API Key here
API_KEY="YOUR_IMMICH_API_KEY"

# Optional: Set to 'true' to only simulate what would be done (no actual API calls for unstacking)
DRY_RUN=false
# Optional: Set to 'true' for more detailed debug output
VERBOSE=false
# --- End Configuration ---

# --- Script Body ---

# Dependency Check
if ! command -v jq &> /dev/null; then
    echo "ERROR: 'jq' is required but not installed or not in PATH."
    echo "Please install jq (e.g., 'sudo apt install jq' or 'brew install jq')."
    exit 1
fi
if ! command -v curl &> /dev/null; then
    echo "ERROR: 'curl' is required but not installed or not in PATH."
    exit 1
fi

# Configuration Validation
if [[ -z "$IMMICH_URL" || "$IMMICH_URL" == "http://your-immich-url.local:2283" ]]; then
    echo "ERROR: Please set the IMMICH_URL variable in the script."
    exit 1
fi
if [[ -z "$API_KEY" || "$API_KEY" == "YOUR_IMMICH_API_KEY" ]]; then
    echo "ERROR: Please set the API_KEY variable in the script."
    exit 1
fi

# Function for debug logging
debug_log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "DEBUG: $1" >&2
    fi
}

# --- Main Logic ---

echo "Fetching all assets from Immich to identify stacks..."
# Fetch only the necessary fields: id and stackParentId
asset_data=$(curl -s -H "x-api-key: ${API_KEY}" -H "Accept: application/json" "${IMMICH_URL}/api/assets?select=id,stackParentId")

if [[ $? -ne 0 ]]; then
    echo "ERROR: Could not fetch assets from Immich. Check URL and API Key."
    exit 1
fi

# Check for empty or invalid JSON response
if ! echo "$asset_data" | jq -e . > /dev/null 2>&1; then
    echo "ERROR: Invalid JSON received from Immich API."
    debug_log "Raw response: $asset_data"
    exit 1
fi

if [[ -z "$asset_data" || "$asset_data" == "[]" ]]; then
    echo "No assets found or API response was empty. Nothing to unstack."
    exit 0
fi

# Associative array to store children for each parent
declare -A parent_to_children

asset_count=$(echo "$asset_data" | jq length)
echo "Processing ${asset_count} assets to find stack relationships..."
processed_count=0

# Iterate through all assets to find children and group them by parent
echo "$asset_data" | jq -c '.[] | select(.stackParentId != null)' | while IFS= read -r asset_json; do
    ((processed_count++))
    # Note: processed_count only increments for children found, might not reach asset_count
    # printf "\rProcessing asset relationships (%d found)..." "$processed_count"

    child_id=$(echo "$asset_json" | jq -r '.id')
    parent_id=$(echo "$asset_json" | jq -r '.stackParentId')

    if [[ -n "$parent_id" && "$parent_id" != "null" ]]; then
        debug_log "Found child '$child_id' belonging to parent '$parent_id'"
        if [[ -n "${parent_to_children[$parent_id]}" ]]; then
            parent_to_children["$parent_id"]+=",${child_id}"
        else
            parent_to_children["$parent_id"]="$child_id"
        fi
    fi
done

echo # Newline after potential progress indicator (if uncommented)

if [[ ${#parent_to_children[@]} -eq 0 ]]; then
    echo "No stacked assets found (no assets have a stackParentId)."
    exit 0
fi

echo "Found ${#parent_to_children[@]} stacks to potentially unstack."

unstack_count=0
error_count=0

# Iterate through each parent that has children
for parent_id in "${!parent_to_children[@]}"; do
    child_ids_string="${parent_to_children[$parent_id]}"
    debug_log "Processing stack for parent '$parent_id' with children: $child_ids_string"

    # Prepare the list of child asset IDs for the API call payload
    child_id_list="["
    first=true
    IFS=',' read -ra current_child_ids <<< "$child_ids_string"
    for child_id in "${current_child_ids[@]}"; do
        if ! $first; then
            child_id_list+=","
        fi
        child_id_list+="\"$child_id\""
        first=false
    done
    child_id_list+="]"

    # Create the JSON payload: { "assetIds": ["childId1", "childId2", ...] }
    json_payload=$(jq -n --argjson ids "$child_id_list" '{assetIds: $ids}')
    debug_log "JSON Payload for parent $parent_id: $json_payload"

    # Define the API endpoint for removing assets from a stack
    # IMPORTANT: Verify this endpoint with the Immich API documentation for your version
    unstack_endpoint="${IMMICH_URL}/api/assets/${parent_id}/stack/remove"

    echo "-> Unstacking children from parent '$parent_id'"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "   DRY RUN: Would call PUT ${unstack_endpoint} with payload: $json_payload"
        ((unstack_count++))
    else
        echo "   Sending API call to unstack..."
        response=$(curl -s -w "\n%{http_code}" -X PUT \
            -H "x-api-key: ${API_KEY}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            --data "$json_payload" \
            "${unstack_endpoint}")

        # Separate body and HTTP status code
        http_code=$(echo "$response" | tail -n1)
        response_body=$(echo "$response" | sed '$d') # Everything except the last line

        # Check HTTP status code for success (Usually 200 OK for PUT updates)
        if [[ $? -eq 0 && "$http_code" -eq 200 ]]; then
            echo "   SUCCESS: Children unstacked from parent '$parent_id' (HTTP $http_code)."
            debug_log "   Response: $response_body"
            ((unstack_count++))
        else
            echo "   ERROR: Could not unstack children from parent '$parent_id' (HTTP $http_code)."
            debug_log "   Endpoint: PUT ${unstack_endpoint}"
            debug_log "   Payload: $json_payload"
            debug_log "   Error Response: $response_body"
            ((error_count++))
            # Optional: More detailed error analysis of the response could be done here
        fi
        sleep 0.5 # Short pause to avoid overwhelming the API
    fi
done

echo "--------------------"
echo "Summary:"
if [[ "$DRY_RUN" == "true" ]]; then
    echo " DRY RUN finished."
    echo " Would attempt to unstack ${unstack_count} stacks."
else
    echo " Script finished."
    echo " ${unstack_count} unstack operations successfully sent."
    echo " ${error_count} errors during unstacking API calls."
fi
echo "--------------------"

exit 0
