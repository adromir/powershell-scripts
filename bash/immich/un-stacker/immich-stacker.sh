#!/bin/bash

# --- Configuration ---
# Enter the URL of your Immich instance here (without a trailing /)
IMMICH_URL="http://your-immich-url.local:2283"
# Enter your Immich API Key here
API_KEY="YOUR_IMMICH_API_KEY"

# --- Filename Matching Configuration ---
# Define lists of extensions to classify files AFTER a regex match.
# Primary extensions (usually the ones you want as stack cover)
PRIMARY_EXTENSIONS=("jpg" "jpeg" "heic" "png" "avif" "webp") # Add more if needed (lowercase)
# Secondary/RAW extensions to be stacked with primary files
RAW_EXTENSIONS=("dng" "cr2" "cr3" "nef" "arw" "orf" "raf" "rw2" "pef" "tif" "tiff") # Add more if needed (lowercase)

# Define POSIX Extended Regular Expression (ERE) patterns to extract the common base name.
# Each pattern MUST contain exactly ONE capturing group (...) that extracts the common identifier.
# The script will try patterns in order until one matches.
# Examples:
#   - Standard camera names like IMG_1234.JPG, DSC0001.ARW: '^([A-Z_]+[0-9]+)\.[^.]+$'
#   - Date-based names like 20240423_173005.jpg: '^([0-9]{8}_[0-9]{6})\.[^.]+$'
#   - Names with suffixes like MyPhoto_Edit.jpg, MyPhoto.dng: '^([a-zA-Z0-9_-]+)(_Edit)?\.[^.]+$' (Captures 'MyPhoto')
#   - Google Photos style PXL_2023...jpg/dng: '^(PXL_[0-9T._+-]+)\.(jpg|dng)$'
FILENAME_REGEX_PATTERNS=(
    '^([A-Z_]+[0-9]+)\.[^.]+$'             # Example: IMG_1234.JPG, _DSC5678.NEF
    '^([0-9]{8}_[0-9]{6})\.[^.]+$'         # Example: 20240423_180515.dng
    '^(PXL_[0-9T._+-]+)\.[^.]+$'           # Example: PXL_20240101_123456.PORTRAIT.jpg
    '^([a-zA-Z0-9_-]+)(_HDR|_Burst[0-9]+)?\.[^.]+$' # Example: MyVacation_HDR.jpg, MyVacation.cr3
    # Add more patterns here if needed, most specific first is often better
)
# --- End Filename Matching Configuration ---


# Optional: Set to 'true' to only simulate what would be done (no actual API calls for stacking)
DRY_RUN=false
# Optional: Set to 'true' for more detailed debug output
VERBOSE=false
# --- End Configuration ---

# --- Script Body (Less likely to need changes below this line) ---

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
if [[ ${#FILENAME_REGEX_PATTERNS[@]} -eq 0 ]]; then
    echo "ERROR: No FILENAME_REGEX_PATTERNS defined in the script. Cannot match files."
    exit 1
fi


# Function for debug logging
debug_log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "DEBUG: $1" >&2
    fi
}

# --- Main Logic ---

echo "Fetching all assets from Immich..."
# Fetch all assets. Assumption: API returns all at once. Adjust if needed for very large libraries.
# We only fetch the fields we actually need to reduce data transfer.
asset_data=$(curl -s -H "x-api-key: ${API_KEY}" -H "Accept: application/json" "${IMMICH_URL}/api/assets?select=id,originalPath,originalFileName,stackCount,stackParentId")

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
    echo "No assets found or API response was empty."
    exit 0
fi

# Arrays to store found assets, grouped by the extracted base name identifier
declare -A primary_files
declare -A raw_files
declare -A asset_details # Stores ID, stackCount, stackParentId

asset_count=$(echo "$asset_data" | jq length)
echo "Processing ${asset_count} assets..."
processed_count=0

# Iterate through each asset and group by the regex-extracted base identifier
echo "$asset_data" | jq -c '.[]' | while IFS= read -r asset_json; do
    ((processed_count++))
    printf "\rProcessing asset %d/%d..." "$processed_count" "$asset_count"

    asset_id=$(echo "$asset_json" | jq -r '.id')
    original_file_name=$(echo "$asset_json" | jq -r '.originalFileName')
    stack_count=$(echo "$asset_json" | jq -r '.stackCount // 0') # // 0 handles null
    stack_parent_id=$(echo "$asset_json" | jq -r '.stackParentId // "null"') # // "null" handles null

    # Store details for later checks
    asset_details["$asset_id,stackCount"]=$stack_count
    asset_details["$asset_id,stackParentId"]=$stack_parent_id

    # Extract extension (lowercase)
    extension_lower=$(echo "${original_file_name##*.}" | tr '[:upper:]' '[:lower:]')

    # Try to match filename against defined regex patterns
    base_name=""
    matched_pattern=false
    for pattern in "${FILENAME_REGEX_PATTERNS[@]}"; do
        if [[ "$original_file_name" =~ $pattern ]]; then
            # Check if the pattern actually captured something
            if [[ -n "${BASH_REMATCH[1]}" ]]; then
                base_name="${BASH_REMATCH[1]}" # Use the first capturing group
                matched_pattern=true
                debug_log "Checking: '$original_file_name' (ID: $asset_id) - Matched pattern '$pattern', extracted base: '$base_name', Ext: '$extension_lower'"
                break # Stop after first match
            else
                 debug_log "WARNING: Pattern '$pattern' matched '$original_file_name', but did not capture a group. Skipping pattern."
            fi
        fi
    done

    # If no pattern matched, skip this asset
    if ! $matched_pattern; then
        debug_log "Skipping: '$original_file_name' (ID: $asset_id) - No regex pattern matched."
        continue
    fi

    # Classify the file based on its extension and store it
    is_primary=false
    for ext in "${PRIMARY_EXTENSIONS[@]}"; do
        if [[ "$extension_lower" == "$ext" ]]; then
            if [[ -n "${primary_files[$base_name]}" ]]; then
                 debug_log "WARNING: Multiple primary files found for base '$base_name'. Skipping '${original_file_name}'. Currently stored: ${primary_files[$base_name]}"
            else
                primary_files["$base_name"]=$asset_id
                debug_log "  -> Classified as Primary (ID: $asset_id)"
            fi
            is_primary=true
            break
        fi
    done

    if ! $is_primary; then
        for ext in "${RAW_EXTENSIONS[@]}"; do
            if [[ "$extension_lower" == "$ext" ]]; then
                if [[ -n "${raw_files[$base_name]}" ]]; then
                     raw_files["$base_name"]="${raw_files[$base_name]},$asset_id"
                     debug_log "  -> Classified as Additional RAW/Secondary (ID: $asset_id)"
                else
                    raw_files["$base_name"]=$asset_id
                    debug_log "  -> Classified as RAW/Secondary (ID: $asset_id)"
                fi
                break # Found its classification
            fi
        done
    fi
done

echo # Newline after progress indicator
echo "Asset processing finished. Searching for pairs to stack..."

stack_count=0
skipped_count=0
error_count=0

# Iterate through the found primary files and look for matching RAWs/Secondaries
for base_name in "${!primary_files[@]}"; do
    primary_id="${primary_files[$base_name]}"

    if [[ -n "${raw_files[$base_name]}" ]]; then
        raw_ids_string="${raw_files[$base_name]}"
        debug_log "Potential stack found for base name '$base_name': Primary ID '$primary_id', RAW/Secondary IDs '$raw_ids_string'"

        # --- Check for existing stack conditions ---
        primary_stack_count=${asset_details["$primary_id,stackCount"]}
        primary_stack_parent=${asset_details["$primary_id,stackParentId"]}

        # 1. Is the primary file already a child of another stack?
        if [[ "$primary_stack_parent" != "null" ]]; then
             debug_log "Skipping '$base_name': Primary file '$primary_id' is already part of a stack (Parent: $primary_stack_parent)."
             ((skipped_count++))
             continue
        fi

        # 2. Check if any of the intended children are already children of THIS primary file
        #    OR if any children are already children of a DIFFERENT stack.
        already_stacked_correctly=false
        skip_due_to_conflict=false
        IFS=',' read -ra current_raw_ids <<< "$raw_ids_string"

        # Fetch stack info only if primary has children OR we need to check raw parents
        stack_info_fetched=false
        stack_info=""
        if [[ $primary_stack_count -gt 0 ]]; then
             stack_info=$(curl -s -H "x-api-key: ${API_KEY}" -H "Accept: application/json" "${IMMICH_URL}/api/assets/${primary_id}?select=stack")
             if [[ $? -eq 0 && -n "$stack_info" ]] && echo "$stack_info" | jq -e '.stack' > /dev/null 2>&1 ; then
                 stack_info_fetched=true
             else
                 debug_log "WARNING: Could not retrieve valid stack details for potential parent $primary_id, cautious skipping might occur."
                 stack_info="" # Ensure it's empty if fetch failed
             fi
        fi

        all_raws_accounted_for=true
        for raw_id in "${current_raw_ids[@]}"; do
            raw_stack_parent=${asset_details["$raw_id,stackParentId"]}

            # 2a. Is this RAW file already stacked under a DIFFERENT parent?
            if [[ "$raw_stack_parent" != "null" && "$raw_stack_parent" != "$primary_id" ]]; then
                debug_log "Skipping '$base_name': RAW/Secondary file '$raw_id' already has a different parent ($raw_stack_parent)."
                skip_due_to_conflict=true
                break # Conflict found, no need to check further RAWs for this base_name
            fi

            # 2b. Is this RAW file already stacked under the CORRECT primary file?
            if [[ "$raw_stack_parent" == "$primary_id" ]]; then
                 # This one is already correctly stacked, continue checking others
                 debug_log "  Info: RAW/Secondary file '$raw_id' is already stacked under '$primary_id'."
                 continue
            fi

            # 2c. If not stacked via parentId, check if it's in the stack children array (covers cases where parentId might be null but stack exists)
            # This check is only useful if the primary ALREADY has children AND we fetched stack info
            if $stack_info_fetched; then
                 if echo "$stack_info" | jq -e --arg rid "$raw_id" '.stack | map(.id) | contains([$rid])' > /dev/null; then
                     debug_log "  Info: RAW/Secondary file '$raw_id' found in stack children of '$primary_id' (even if parentId was null)."
                     continue # Already part of the stack
                 fi
            fi

            # If we reach here, this specific raw_id is NOT yet correctly stacked under primary_id
            all_raws_accounted_for=false

        done # End loop through raw_ids for checks

        if $skip_due_to_conflict; then
            ((skipped_count++))
            continue # Go to the next base_name
        fi

        if $all_raws_accounted_for; then
            debug_log "Skipping '$base_name': All identified RAW/Secondary files are already correctly associated with primary '$primary_id'."
            ((skipped_count++))
            continue # Go to the next base_name
        fi
        # --- End Check ---


        echo "-> Stack for '$base_name': Primary '$primary_id' with RAW/Secondary(s) '$raw_ids_string'"

        # Prepare the list of asset IDs for the API call
        # Include the primary ID and ALL RAW/Secondary IDs found for this base name
        asset_id_list="[\"$primary_id\""
        IFS=',' read -ra current_raw_ids_for_payload <<< "$raw_ids_string"
        for raw_id in "${current_raw_ids_for_payload[@]}"; do
            asset_id_list+=",\"$raw_id\""
        done
        asset_id_list+="]"

        # Create the JSON payload
        json_payload=$(jq -n --argjson ids "$asset_id_list" '{assetIds: $ids}')
        debug_log "JSON Payload: $json_payload"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "   DRY RUN: Would stack assets: $json_payload"
            ((stack_count++))
        else
            echo "   Sending API call to stack..."
            response=$(curl -s -w "\n%{http_code}" -X POST \
                -H "x-api-key: ${API_KEY}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                --data "$json_payload" \
                "${IMMICH_URL}/api/assets/stack")

            # Separate body and HTTP status code
            http_code=$(echo "$response" | tail -n1)
            response_body=$(echo "$response" | sed '$d') # Everything except the last line

            # Check HTTP status code for success (200 OK or 201 Created)
            if [[ $? -eq 0 && ( "$http_code" -eq 200 || "$http_code" -eq 201 ) ]]; then
                echo "   SUCCESS: Assets for '$base_name' stacked (HTTP $http_code)."
                debug_log "   Response: $response_body"
                ((stack_count++))
                # Update local cache to prevent re-stacking attempts in the same run if needed
                # (More complex, omitted for now - relies on next run picking up changes)

            else
                echo "   ERROR: Could not stack assets for '$base_name' (HTTP $http_code)."
                debug_log "   Error Response: $response_body"
                ((error_count++))
                # Optional: More detailed error analysis of the response could be done here
            fi
            sleep 0.5 # Short pause to avoid overwhelming the API
        fi
    fi
done

echo "--------------------"
echo "Summary:"
if [[ "$DRY_RUN" == "true" ]]; then
    echo " DRY RUN finished."
    echo " Would attempt to create/update ${stack_count} stacks."
else
    echo " Script finished."
    echo " ${stack_count} stack operations successfully sent."
    echo " ${error_count} errors during stacking API calls."
fi
echo " ${skipped_count} potential stacks skipped (likely already stacked correctly or had conflicts)."
echo "--------------------"

exit 0
