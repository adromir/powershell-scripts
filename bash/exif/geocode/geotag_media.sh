#!/bin/bash

# Bash script to search for image/MP4 files, query APIs for GPS data based on creation date,
# optionally perform reverse geocoding, and write EXIF/XMP tags using exiftool.
# Includes a GUI for configuration using zenity.

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
# set -u # Disabled for now as checking associative array keys can be tricky with this
# Pipe commands should fail if any command in the pipe fails.
set -o pipefail

# --- Configuration Defaults & File Handling ---
CONFIG_DIR="$HOME/.config/exif-updater"
CONFIG_FILE="$CONFIG_DIR/config.json"
DEFAULT_DAWARICH_API_URL="https://your-api-host.com/api/v1/points"
DEFAULT_DAWARICH_API_KEY="YOUR_API_KEY"
DEFAULT_PHOTON_API_URL="https://photon.komoot.io"
DEFAULT_TIME_WINDOW_SECONDS=60
DEFAULT_EXIFTOOL_PATH="exiftool"
DEFAULT_OVERWRITE_EXISTING="false"
DEFAULT_ALWAYS_QUERY_PHOTON="false"

# Associative array to hold configuration
declare -A config

# --- Helper Functions ---

# Function to log messages
log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1" >&2 # Write warnings to stderr
}

log_error() {
    echo "[ERROR] $1" >&2 # Write errors to stderr
}

log_verbose() {
    # Simple verbose logging - enable by setting VERBOSE=true env var
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[VERBOSE] $1"
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect the package manager
detect_package_manager() {
    if command_exists apt-get; then
        echo "apt"
    elif command_exists yum; then
        echo "yum"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists pacman; then
        echo "pacman"
    elif command_exists zypper; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# Function to install packages if missing
install_if_missing() {
    local pkg_manager=$1
    shift
    local packages=("$@")
    local missing_packages=()

    for pkg in "${packages[@]}"; do
        if ! command_exists "$pkg"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -eq 0 ]; then
        return 0 # All dependencies met
    fi

    log_warn "The following dependencies are missing: ${missing_packages[*]}. Attempting installation..."

    case "$pkg_manager" in
        apt)
            sudo apt-get update && sudo apt-get install -y "${missing_packages[@]}"
            ;;
        yum)
            sudo yum install -y "${missing_packages[@]}"
            ;;
        dnf)
            sudo dnf install -y "${missing_packages[@]}"
            ;;
        pacman)
            sudo pacman -Syu --noconfirm "${missing_packages[@]}"
            ;;
        zypper)
            sudo zypper install -y "${missing_packages[@]}"
            ;;
        *)
            log_error "Unsupported package manager. Please install the following packages manually: ${missing_packages[*]}"
            return 1
            ;;
    esac

    # Verify installation after attempt
    for pkg in "${missing_packages[@]}"; do
        if ! command_exists "$pkg"; then
            log_error "Failed to install '$pkg'. Please install it manually and re-run the script."
            return 1
        fi
    done
    log_info "Dependencies installed successfully."
    return 0
}

# Function to load configuration from JSON file
# Handles backward compatibility for renamed keys
load_configuration() {
    log_verbose "Loading configuration from $CONFIG_FILE"
    # Set defaults first
    config["dawarichApiUrl"]="$DEFAULT_DAWARICH_API_URL"
    config["dawarichApiKey"]="$DEFAULT_DAWARICH_API_KEY"
    config["photonApiUrl"]="$DEFAULT_PHOTON_API_URL"
    config["defaultTimeWindowSeconds"]="$DEFAULT_TIME_WINDOW_SECONDS"
    config["exiftoolPath"]="$DEFAULT_EXIFTOOL_PATH"
    config["overwriteExisting"]="$DEFAULT_OVERWRITE_EXISTING"
    config["alwaysQueryPhoton"]="$DEFAULT_ALWAYS_QUERY_PHOTON"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_verbose "Configuration file '$CONFIG_FILE' not found. Using defaults."
        return
    fi

    # Read file content, handle potential errors
    local json_content
    json_content=$(cat "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$json_content" ]]; then
         log_warn "Configuration file '$CONFIG_FILE' is empty or unreadable. Using defaults."
         return
    fi

    # Check if jq output is valid JSON (basic check)
    if ! echo "$json_content" | jq empty 2>/dev/null; then
        log_warn "Configuration file '$CONFIG_FILE' contains invalid JSON. Using defaults."
        return
    fi

    # Load values using jq, checking for new and old keys
    local val
    # Dawarich API URL
    val=$(echo "$json_content" | jq -r '.dawarichApiUrl // .gpsApiUrl // empty')
    if [[ -n "$val" && "$val" != "null" ]]; then config["dawarichApiUrl"]="$val"; fi
    # Dawarich API Key
    val=$(echo "$json_content" | jq -r '.dawarichApiKey // .gpsApiKey // empty')
    if [[ -n "$val" && "$val" != "null" ]]; then config["dawarichApiKey"]="$val"; fi
    # Photon API URL
    val=$(echo "$json_content" | jq -r '.photonApiUrl // .komootApiUrl // empty')
    if [[ -n "$val" && "$val" != "null" ]]; then config["photonApiUrl"]="$val"; fi
    # Time Window
    val=$(echo "$json_content" | jq -r '.defaultTimeWindowSeconds // empty')
    if [[ "$val" =~ ^[0-9]+$ ]]; then config["defaultTimeWindowSeconds"]="$val"; fi
    # Exiftool Path
    val=$(echo "$json_content" | jq -r '.exiftoolPath // empty')
    if [[ -n "$val" && "$val" != "null" ]]; then config["exiftoolPath"]="$val"; fi
    # Overwrite Existing
    val=$(echo "$json_content" | jq -r '.overwriteExisting // empty')
    if [[ "$val" == "true" || "$val" == "false" ]]; then config["overwriteExisting"]="$val"; fi
    # Always Query Photon
    val=$(echo "$json_content" | jq -r '.alwaysQueryPhoton // empty')
    if [[ "$val" == "true" || "$val" == "false" ]]; then config["alwaysQueryPhoton"]="$val"; fi

    log_verbose "Configuration loaded successfully."
}

# Function to save configuration to JSON file
save_configuration() {
    log_verbose "Saving configuration to $CONFIG_FILE"
    mkdir -p "$CONFIG_DIR" # Ensure directory exists

    # Create JSON content using jq
    local json_output
    json_output=$(jq -n \
        --arg dau "${config[dawarichApiUrl]}" \
        --arg dak "${config[dawarichApiKey]}" \
        --arg pau "${config[photonApiUrl]}" \
        --argjson dtw "${config[defaultTimeWindowSeconds]}" \
        --arg etp "${config[exiftoolPath]}" \
        --argjson oe "${config[overwriteExisting]}" \
        --argjson aqp "${config[alwaysQueryPhoton]}" \
        '{dawarichApiUrl: $dau, dawarichApiKey: $dak, photonApiUrl: $pau, defaultTimeWindowSeconds: $dtw, exiftoolPath: $etp, overwriteExisting: $oe, alwaysQueryPhoton: $aqp}')

    # Check if jq succeeded
     if [[ $? -ne 0 || -z "$json_output" ]]; then
        log_error "Failed to generate JSON for saving configuration."
        return 1
    fi

    # Write to file
    if echo "$json_output" > "$CONFIG_FILE"; then
        log_info "Configuration saved successfully."
    else
        log_error "Failed to write configuration file '$CONFIG_FILE'."
        return 1
    fi
}

# Function to show configuration GUI using zenity
show_configuration_gui() {
    local title="EXIF Updater Configuration"
    local text="Configure API settings and options:"

    # Zenity form fields. Format: --add-entry="Label" --add-...
    # Need to capture output carefully. Use a separator unlikely to be in text fields.
    local sep="%%%%"
    local output
    output=$(zenity --forms --title="$title" --text="$text" --separator="$sep" \
        --add-entry="Dawarich API URL:" \
        --add-entry="Dawarich API Key:" \
        --add-entry="Photon API URL:" \
        --add-entry="API Time Window (seconds):" \
        --add-entry="Exiftool Path:" \
        --add-combo="Overwrite existing data?" --combo-values="false|true" \
        --add-combo="Always query Photon API?" --combo-values="false|true" \
        --add-combo="Save settings?" --combo-values="false|true" \
        --text-info --filename=/dev/null \
        "${config[dawarichApiUrl]}" \
        "${config[dawarichApiKey]}" \
        "${config[photonApiUrl]}" \
        "${config[defaultTimeWindowSeconds]}" \
        "${config[exiftoolPath]}" \
        "${config[overwriteExisting]}" \
        "${config[alwaysQueryPhoton]}" \
        "false" # Default for "Save settings?" is false
    )

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_info "Configuration cancelled by user."
        return 1 # Indicate cancellation
    fi

    # Parse the output using the separator
    IFS="$sep" read -r d_url d_key p_url t_win e_path o_exist a_photon save <<< "$output"

    # --- Validate Inputs ---
    local errors=""
    if [[ -z "$d_url" ]]; then errors+="Dawarich API URL cannot be empty.\n"; fi
    if [[ -z "$d_key" ]]; then errors+="Dawarich API Key cannot be empty.\n"; fi
    if [[ -z "$p_url" ]]; then errors+="Photon API URL cannot be empty.\n"; fi
    if ! [[ "$t_win" =~ ^[0-9]+$ ]]; then errors+="API Time Window must be a non-negative integer.\n"; fi
    if [[ -z "$e_path" ]]; then errors+="Exiftool Path cannot be empty.\n"; fi

    if [[ -n "$errors" ]]; then
        zenity --error --title="Input Error" --text="Invalid configuration settings:\n\n$errors"
        return 1 # Indicate validation failure
    fi

    # Update config array
    config["dawarichApiUrl"]="$d_url"
    config["dawarichApiKey"]="$d_key"
    config["photonApiUrl"]="$p_url"
    config["defaultTimeWindowSeconds"]="$t_win"
    config["exiftoolPath"]="$e_path"
    config["overwriteExisting"]="$o_exist"
    config["alwaysQueryPhoton"]="$a_photon"
    config["saveConfig"]="$save" # Temporary key to indicate saving preference

    return 0 # Success
}

# Function to select a folder via GUI
select_folder_dialog() {
    local description="$1"
    local initial_dir="${2:-$HOME/Pictures}" # Default to Pictures if not provided

    local selected_folder
    selected_folder=$(zenity --file-selection --directory --title="$description" --filename="$initial_dir/")

    if [[ $? -ne 0 || -z "$selected_folder" ]]; then
        log_warn "No folder selected. Exiting script."
        exit 1
    fi
    echo "$selected_folder"
}

# Function to convert EXIF date/time to ISO8601 UTC (YYYY-MM-DDTHH:MM:SSZ)
# Handles common 'YYYY:MM:DD HH:MM:SS' format and potential timezone offsets
convert_to_api_timestamp() {
    local exif_dt_str="$1"
    local parsed_date=""

    if [[ -z "$exif_dt_str" ]]; then
        echo ""
        return
    fi

    # Clean the string: remove subseconds, replace separators for 'date' command
    # Input examples: '2023:10:27 15:30:00', '2023:10:27 15:30:00+02:00', '2023:10:27 15:30:00.123'
    local cleaned_str="${exif_dt_str}"
    # Remove subseconds if present
    cleaned_str="${cleaned_str%%.*}"
    # Replace first 2 colons with hyphens, space with T (for ISO-like format)
    cleaned_str="${cleaned_str/:/-}"
    cleaned_str="${cleaned_str/:/-}"
    cleaned_str="${cleaned_str/ /T}"
    # Remove colon in timezone offset if present (e.g., +02:00 -> +0200)
    cleaned_str="${cleaned_str/%:??/${cleaned_str: -5:3}${cleaned_str: -2:2}}"

    # Try parsing using 'date'. The '-d' flag is powerful but can be finicky.
    # We assume the date string represents local time unless it has a timezone offset.
    parsed_date=$(date -u -d "$cleaned_str" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

    if [[ $? -ne 0 || -z "$parsed_date" ]]; then
        log_warn "Could not parse date '$exif_dt_str' (cleaned: '$cleaned_str')."
        echo ""
    else
        log_verbose "Converted '$exif_dt_str' to '$parsed_date'"
        echo "$parsed_date"
    fi
}

# Function to call the Dawarich API
# Args: BaseUrl, ApiKey, StartAt (UTC), EndAt (UTC)
get_dawarich_data_from_api() {
    local base_url="$1"
    local api_key="$2"
    local start_at="$3"
    local end_at="$4"

    # URL encode timestamps (simple encoding for ':' and '+')
    local encoded_start_at="${start_at//:/%3A}"
    encoded_start_at="${encoded_start_at//+/%2B}"
    local encoded_end_at="${end_at//:/%3A}"
    encoded_end_at="${encoded_end_at//+/%2B}"

    local api_url="${base_url}?api_key=${api_key}&start_at=${encoded_start_at}&end_at=${encoded_end_at}&order=asc"
    log_verbose "Querying Dawarich API: $api_url"

    local response
    # Use curl with timeout, silent mode (-s), show errors (-S), fail on HTTP errors (-f)
    response=$(curl -sS -f --connect-timeout 15 --max-time 120 "$api_url")
    local curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 ]]; then
        log_error "Error querying Dawarich API (Exit code: $curl_exit_code). URL: $api_url"
        # Attempt to show response if available (curl might print it even on error)
        if [[ -n "$response" ]]; then log_error "API Response: $response"; fi
        echo "" # Return empty on error
        return 1
    fi

    # Check if response is valid JSON using jq
    if ! echo "$response" | jq empty 2>/dev/null; then
        log_error "Invalid JSON response from Dawarich API. URL: $api_url"
        log_error "API Response: $response"
        echo ""
        return 1
    fi

    echo "$response"
    return 0
}

# Function to call the Photon API for Reverse Geocoding
# Args: BaseUrl, Latitude, Longitude
get_location_from_photon() {
    local base_url="$1"
    local latitude="$2"
    local longitude="$3"

    local photon_reverse_url="${base_url}/reverse?lat=${latitude}&lon=${longitude}"
    log_verbose "Querying Photon API: $photon_reverse_url"

    local response
    response=$(curl -sS -f --connect-timeout 10 --max-time 60 "$photon_reverse_url")
    local curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 ]]; then
        log_error "Error querying Photon API (Exit code: $curl_exit_code). URL: $photon_reverse_url"
        if [[ -n "$response" ]]; then log_error "API Response: $response"; fi
        echo "" # Return empty on error
        return 1
    fi

     # Check if response is valid JSON
    if ! echo "$response" | jq empty 2>/dev/null; then
        log_error "Invalid JSON response from Photon API. URL: $photon_reverse_url"
        log_error "API Response: $response"
        echo ""
        return 1
    fi

    # Extract data using jq
    local country city country_code
    country=$(echo "$response" | jq -r '.features[0].properties.country // ""')
    city=$(echo "$response" | jq -r '.features[0].properties.city // .features[0].properties.county // .features[0].properties.state // ""')
    country_code=$(echo "$response" | jq -r '.features[0].properties.countrycode // ""')

    # Return results as a JSON string for easier parsing by caller
    jq -n --arg co "$country" --arg ci "$city" --arg cc "$country_code" \
        '{Country: $co, City: $ci, CountryCode: $cc}'
    return 0
}

# Function to write EXIF/XMP data using exiftool
# Args: ExiftoolExePath, FilePath, Latitude, Longitude, Country, City, CountryCode
set_exif_data() {
    local exiftool_exe_path="$1"
    local file_path="$2"
    local latitude="$3"
    local longitude="$4"
    local country="$5"
    local city="$6"
    local country_code="$7"

    local filename base_filename extension is_mp4 xmp_file_path
    filename=$(basename "$file_path")
    base_filename="${filename%.*}"
    extension="${filename##*.}"
    extension_lower=$(echo "$extension" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

    is_mp4=false
    if [[ "$extension_lower" == "mp4" ]]; then
        is_mp4=true
    fi

    # Convert Lat/Lon to required format
    local lat_ref="N" lon_ref="E"
    local lat_abs lon_abs
    if (( $(echo "$latitude < 0" | bc -l) )); then lat_ref="S"; fi
    if (( $(echo "$longitude < 0" | bc -l) )); then lon_ref="E"; fi # Corrected LonRef logic
    lat_abs=$(echo "$latitude" | awk '{print ($1<0) ? -$1 : $1}')
    lon_abs=$(echo "$longitude" | awk '{print ($1<0) ? -$1 : $1}')


    # Build tag arguments array
    local -a tag_args=()
    tag_args+=("-GPSLatitude=$lat_abs")
    tag_args+=("-GPSLatitudeRef=$lat_ref")
    tag_args+=("-GPSLongitude=$lon_abs")
    tag_args+=("-GPSLongitudeRef=$lon_ref")
    if [[ -n "$country" ]]; then tag_args+=("-Country=$country"); fi
    if [[ -n "$city" ]]; then tag_args+=("-City=$city"); fi
    if [[ -n "$country_code" ]]; then tag_args+=("-XMP-iptcCore:CountryCode=$country_code"); fi

    # Determine output target and specific arguments
    local -a exif_args=()
    local output_target_description=""
    local xmp_file_path="${file_path%.*}.xmp" # Path for potential sidecar

    if [[ "$is_mp4" == true ]]; then
        output_target_description="XMP sidecar '$base_filename.xmp'"
        # Delete existing XMP sidecar for MP4 to ensure overwrite via -o
        if [[ -f "$xmp_file_path" ]]; then
            log_verbose "Removing existing XMP sidecar: $xmp_file_path"
            rm -f "$xmp_file_path"
        fi
        exif_args+=("${tag_args[@]}")
        exif_args+=("-o" "$xmp_file_path") # Output to new sidecar
        # No source file needed as final arg when creating sidecar from tags
    else
        # For non-MP4 (images), check if sidecar exists
        if [[ -f "$xmp_file_path" ]]; then
            # Sidecar exists for image, update it
            output_target_description="existing XMP sidecar '$base_filename.xmp'"
            exif_args+=("${tag_args[@]}")
            exif_args+=("-o" "$xmp_file_path") # Output/update sidecar
            exif_args+=("$file_path")         # Source file needed when updating sidecar
        else
            # Sidecar does not exist for image, write directly to image file
            output_target_description="file '$filename'"
            exif_args+=("-overwrite_original")
            exif_args+=("${tag_args[@]}")
            exif_args+=("$file_path")
        fi
    fi

    # Execute Exiftool
    log_verbose "Executing exiftool write to $output_target_description"
    log_verbose "Command: $exiftool_exe_path ${exif_args[*]}"

    local exiftool_output exiftool_error
    # Capture stdout and stderr separately
    {
        exiftool_output=$("$exiftool_exe_path" "${exif_args[@]}" 2> >(exiftool_error=$(cat); cat >&2))
    }
    local exiftool_exit_code=$?

    log_verbose "Exiftool Exit Code: $exiftool_exit_code"
    if [[ -n "$exiftool_output" ]]; then log_verbose "Exiftool Stdout: $exiftool_output"; fi
    if [[ -n "$exiftool_error" ]]; then log_verbose "Exiftool Stderr: $exiftool_error"; fi

    # Check exit code and output/error messages
    if [[ $exiftool_exit_code -ne 0 ]]; then
        # Exit Code 1 might mean "Nothing to write" which is not a fatal error here
        if [[ $exiftool_exit_code -eq 1 && ("$exiftool_error" == *"Nothing to write"* || "$exiftool_output" == *"0 image files updated"* || "$exiftool_output" == *"0 output files created"*) ]]; then
            log_info "    -> No changes needed for ${output_target_description} (Tags likely identical)."
            # Print other warnings if they exist
            if [[ -n "$exiftool_error" && "$exiftool_error" != *"Nothing to write"* ]]; then
                 log_warn "Exiftool write warnings: $exiftool_error"
            fi
            return 0 # Treat as success/non-fatal
        else
            log_error "Exiftool write operation failed (code $exiftool_exit_code) for ${output_target_description}."
            if [[ -n "$exiftool_error" ]]; then log_error "Stderr: $exiftool_error"; fi
            if [[ -n "$exiftool_output" ]]; then log_error "Stdout: $exiftool_output"; fi
            return 1 # Real error
        fi
    else
        local success_msg="Metadata successfully written to"
        if [[ "$is_mp4" == false && ! -f "$xmp_file_path" ]]; then
            success_msg="EXIF data successfully written to"
        fi
        log_info "    -> $success_msg ${output_target_description}."
         # Print unexpected output/errors as warnings
        if [[ -n "$exiftool_output" && "$exiftool_output" != *"1 image files updated"* && "$exiftool_output" != *"1 output files created"* ]]; then
             log_warn "Exiftool write output: $exiftool_output"
        fi
        if [[ -n "$exiftool_error" ]]; then
             log_warn "Exiftool write warnings: $exiftool_error"
        fi
        return 0 # Success
    fi
}

# --- Main Script Logic ---

# 0. Check Dependencies
log_info "Checking dependencies: exiftool, jq, zenity..."
pkg_mgr=$(detect_package_manager)
if [[ "$pkg_mgr" == "unknown" ]]; then
    log_warn "Could not detect package manager. Please ensure 'exiftool', 'jq', and 'zenity' are installed."
    if ! command_exists exiftool || ! command_exists jq || ! command_exists zenity; then
        log_error "Required commands not found. Please install them manually."
        exit 1
    fi
else
    # Attempt installation if needed (requires sudo)
    if ! install_if_missing "$pkg_mgr" "exiftool" "jq" "zenity"; then
        log_error "Dependency installation failed or required manual intervention. Exiting."
        exit 1
    fi
fi
log_info "Dependencies met."


# 0a. Load Config
load_configuration

# 0b. Show GUI for Configuration
if ! show_configuration_gui; then
    exit 1 # User cancelled or validation failed
fi

# 0c. Save Config if requested
if [[ "${config[saveConfig]}" == "true" ]]; then
    save_configuration
fi
# Remove temporary key
unset config[saveConfig]

# 0d. Pre-checks (Exiftool Path)
exiftool_path_to_use="${config[exiftoolPath]}"
if ! command_exists "$exiftool_path_to_use"; then
    # Try finding exiftool in PATH if configured path doesn't work
    if command_exists exiftool; then
        exiftool_path_to_use=$(command -v exiftool)
        log_warn "Exiftool not found at configured path '${config[exiftoolPath]}', but found in system PATH: $exiftool_path_to_use. Using this path."
        config["exiftoolPath"]="$exiftool_path_to_use" # Update config in memory
    else
         zenity --error --title="Exiftool Not Found" --text="Exiftool could not be found at '${config[exiftoolPath]}' or in the system PATH. Please check the path in the configuration or ensure exiftool is installed correctly."
         log_error "Exiftool could not be found. Exiting script."
         exit 1
    fi
fi
log_info "Using exiftool: $exiftool_path_to_use"
if [[ "${config[overwriteExisting]}" == "true" ]]; then log_info "Overwrite existing data flag is ON."; fi
if [[ "${config[alwaysQueryPhoton]}" == "true" ]]; then log_info "Always Query Photon flag is ON."; fi


# 1. Select Folder
target_folder=$(select_folder_dialog "Select the folder containing image/video files")
log_info "Processing folder: $target_folder"

# 2. File Extensions
image_extensions=("jpg" "jpeg" "png" "tiff" "heic" "gif" "cr2" "dng")
video_extensions=("mp4")
all_extensions=("${image_extensions[@]}" "${video_extensions[@]}")

# Build find command name pattern
find_pattern="("
first_ext=true
for ext in "${all_extensions[@]}"; do
    if [[ "$first_ext" == false ]]; then find_pattern+=" -o"; fi
    find_pattern+=" -iname '*.${ext}'"
    first_ext=false
done
find_pattern+=")"

# Large file threshold (in bytes)
large_file_threshold_mb=200
large_file_threshold_bytes=$((large_file_threshold_mb * 1024 * 1024))

# 3. Find Files
log_info "Searching for files with extensions: ${all_extensions[*]}"
# Use find -print0 and read -d '' to handle filenames with spaces/special chars
mapfile -d '' files_to_process < <(find "$target_folder" -maxdepth 1 -type f $find_pattern -print0)

if [[ ${#files_to_process[@]} -eq 0 ]]; then
    log_warn "No matching files found in folder '$target_folder'."
    exit 0
fi

log_info "${#files_to_process[@]} files found. Starting processing..."
processed_count=0
updated_count=0
error_count=0

# 4. & 5. Process Files
for file_path in "${files_to_process[@]}"; do
    # Skip empty entries that might occur with find/mapfile
    if [[ -z "$file_path" ]]; then continue; fi

    ((processed_count++))
    filename=$(basename "$file_path")
    log_info "[$processed_count/${#files_to_process[@]}] Processing file: $filename"
    file_had_error=false

    # Check file size
    file_size=$(stat -c%s "$file_path")
    if [[ $file_size -gt $large_file_threshold_bytes ]]; then
        log_info "    -> Large file detected ($((file_size / 1024 / 1024)) MB). Exiftool processing may take some time..."
    fi

    # Read EXIF data using exiftool -j (JSON output)
    # Tags: GPS coords, Country, City, CountryCode (XMP), various date tags, FilePath
    exif_read_args=(
        "-j" "-GPSLatitude" "-GPSLongitude" "-Country" "-City" "-XMP-iptcCore:CountryCode"
        "-DateTimeOriginal" "-CreateDate" "-MediaCreateDate" "-TrackCreateDate" "-FilePath"
    )
    local exif_json exif_data
    log_verbose "Executing exiftool read: $exiftool_path_to_use ${exif_read_args[*]} \"$file_path\""
    exif_json=$("$exiftool_path_to_use" "${exif_read_args[@]}" "$file_path" 2>/dev/null)
    exiftool_read_exit=$?

    if [[ $exiftool_read_exit -ne 0 ]]; then
         log_warn "    Exiftool read command failed (code $exiftool_read_exit) for '$filename'."
         # Sometimes exiftool exits 0 but prints error to stdout if file has issues
         if [[ "$exif_json" == *"Error:"* ]]; then
             log_warn "    Exiftool read output indicates error: $exif_json"
         fi
         file_had_error=true; ((error_count++)); continue
    fi

    if [[ -z "$exif_json" ]]; then
        log_warn "    Exiftool read operation produced no output for '$filename'. Skipping."
        continue
    fi

    # Exiftool -j wraps output in an array, even for one file. Extract the first element.
    # Also check if the output is valid JSON.
    if ! echo "$exif_json" | jq -e '.[0]' > /dev/null; then
         log_warn "    Failed to parse JSON or empty array from exiftool read for '$filename'. Raw output: $exif_json"
         file_had_error=true; ((error_count++)); continue
    fi
    exif_data=$(echo "$exif_json" | jq '.[0]') # Get the first object

    # Check existing tags using jq
    gps_lat=$(echo "$exif_data" | jq -r '.GPSLatitude // null')
    gps_lon=$(echo "$exif_data" | jq -r '.GPSLongitude // null')
    country=$(echo "$exif_data" | jq -r '.Country // null')
    city=$(echo "$exif_data" | jq -r '.City // null')
    country_code=$(echo "$exif_data" | jq -r '."XMP-iptcCore:CountryCode" // null') # Note the quotes for the key

    # Determine if processing is needed
    should_process_file=false
    if [[ "${config[overwriteExisting]}" == "true" ]]; then
        should_process_file=true
        log_info "    -> Overwrite flag set. Processing file..."
    else
        local reason=""
        if [[ "$gps_lat" == "null" || "$gps_lon" == "null" || ("$gps_lat" == "0" && "$gps_lon" == "0") ]]; then reason+="GPS coordinates missing or zero. "; should_process_file=true; fi
        if [[ "$country" == "null" || -z "$country" ]]; then reason+="Country missing. "; should_process_file=true; fi
        if [[ "$city" == "null" || -z "$city" ]]; then reason+="City missing. "; should_process_file=true; fi
        if [[ "$country_code" == "null" || -z "$country_code" ]]; then reason+="Country Code missing. "; should_process_file=true; fi
        if [[ "$should_process_file" == true ]]; then log_info "    -> Processing needed: $reason"; fi
    fi

    if [[ "$should_process_file" == false ]]; then
        log_info "    -> File does not need processing (has data and overwrite flag is off)."
        continue
    fi

    # --- Proceed with processing ---

    # Determine creation date (try tags in order of preference)
    creation_date_string=$(echo "$exif_data" | jq -r '.DateTimeOriginal // .CreateDate // .MediaCreateDate // .TrackCreateDate // null')

    if [[ "$creation_date_string" == "null" || -z "$creation_date_string" ]]; then
        log_warn "    Could not determine suitable creation date from EXIF for '$filename'. Skipping."
        file_had_error=true; ((error_count++)); continue
    fi

    # Convert date for API
    file_timestamp_utc=$(convert_to_api_timestamp "$creation_date_string")
    if [[ -z "$file_timestamp_utc" ]]; then
        log_warn "    Could not convert creation date '$creation_date_string' for API. Skipping."
        file_had_error=true; ((error_count++)); continue
    fi

    # Parse the UTC timestamp back into seconds since epoch for calculations
    file_datetime_epoch=$(date -u -d "$file_timestamp_utc" +%s 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log_warn "    Failed to parse back converted UTC timestamp '$file_timestamp_utc' to epoch seconds. Skipping."
        file_had_error=true; ((error_count++)); continue
    fi

    log_info "    Determined creation date (UTC): $file_timestamp_utc"

    # --- Dawarich API Query ---
    log_info "    Attempting exact Dawarich API query for $file_timestamp_utc..."
    api_result_exact_json=$(get_dawarich_data_from_api "${config[dawarichApiUrl]}" "${config[dawarichApiKey]}" "$file_timestamp_utc" "$file_timestamp_utc")
    best_match_json="" # Store the best matching JSON object string

    if [[ -n "$api_result_exact_json" ]]; then
        # Filter results: must have lat/lon, not be null, not be 0,0
        # Use jq to filter and select the first valid result
        best_match_json=$(echo "$api_result_exact_json" | jq -c '[.[] | select(.latitude != null and .longitude != null and (.latitude != 0 or .longitude != 0))] | .[0] // empty')
        if [[ -n "$best_match_json" && "$best_match_json" != "null" ]]; then
            log_info "    -> Exact match found."
        else
            log_info "    -> Exact query returned results, but without valid coordinates or no results."
            best_match_json="" # Ensure it's empty
        fi
    else
        log_info "    -> Dawarich API query failed or returned null/empty for exact match."
    fi

    # If no exact match, try time window
    if [[ -z "$best_match_json" ]]; then
        start_epoch=$((file_datetime_epoch - ${config[defaultTimeWindowSeconds]}))
        end_epoch=$((file_datetime_epoch + ${config[defaultTimeWindowSeconds]}))
        start_date_utc=$(date -u -d "@$start_epoch" +"%Y-%m-%dT%H:%M:%SZ")
        end_date_utc=$(date -u -d "@$end_epoch" +"%Y-%m-%dT%H:%M:%SZ")

        log_info "    Attempting Dawarich API query within time window: $start_date_utc to $end_date_utc..."
        api_result_range_json=$(get_dawarich_data_from_api "${config[dawarichApiUrl]}" "${config[dawarichApiKey]}" "$start_date_utc" "$end_date_utc")

        if [[ -n "$api_result_range_json" ]]; then
            # Filter valid results
            valid_results_range_json=$(echo "$api_result_range_json" | jq -c '[.[] | select(.latitude != null and .longitude != null and (.latitude != 0 or .longitude != 0))]')

            if [[ $(echo "$valid_results_range_json" | jq 'length') -gt 0 ]]; then
                 log_info "    -> $(echo "$valid_results_range_json" | jq 'length') valid results found in time window. Finding closest..."
                 # Use jq to find the result closest in time (requires timestamp field in API response)
                 # Assuming timestamp is epoch seconds or ISO8601 string
                 best_match_json=$(echo "$valid_results_range_json" | jq -c --argjson target_epoch "$file_datetime_epoch" '
                    map(
                        . + {
                            # Calculate time difference in seconds
                            diff: (
                                if .timestamp? | type == "number" then .timestamp # Assume epoch seconds
                                elif .timestamp? | type == "string" then (.timestamp | fromdateiso8601) # Parse ISO8601
                                else null end
                                | if . == null then null else . - $target_epoch |.*. end # Absolute difference
                            )
                        }
                    ) |
                    # Filter out entries where diff couldn't be calculated
                    map(select(.diff != null)) |
                    # Sort by difference
                    sort_by(.diff) |
                    # Get the first one (closest)
                    .[0] // empty
                 ')

                 if [[ -n "$best_match_json" && "$best_match_json" != "null" ]]; then
                     closest_diff=$(echo "$best_match_json" | jq '.diff')
                     # Remove the temporary diff field before using the result
                     best_match_json=$(echo "$best_match_json" | jq 'del(.diff)')
                     log_info "    -> Closest match found (Difference: ${closest_diff}s)."
                 else
                     log_info "    -> Could not find a valid, time-comparable result in the window (missing/invalid timestamps?)."
                     best_match_json=""
                 fi
            else
                log_info "    -> API query (time window) returned results, but none with valid coordinates."
            fi
        else
            log_info "    -> Dawarich API query failed or returned null/empty for time window."
        fi
    fi

    # --- Process Best Match (if found) ---
    if [[ -n "$best_match_json" && "$best_match_json" != "null" ]]; then
        latitude=$(echo "$best_match_json" | jq -r '.latitude')
        longitude=$(echo "$best_match_json" | jq -r '.longitude')

        # Get initial values from Dawarich API result
        country_from_dawarich=$(echo "$best_match_json" | jq -r '.country // ""')
        city_from_dawarich=$(echo "$best_match_json" | jq -r '.city // ""')
        # Assuming field name 'country_code' in Dawarich response
        country_code_from_dawarich=$(echo "$best_match_json" | jq -r '.country_code // ""')

        # Initialize variables for writing
        country_to_write="$country_from_dawarich"
        city_to_write="$city_from_dawarich"
        country_code_to_write="$country_code_from_dawarich"

        # --- Photon Reverse Geocoding (if needed or forced) ---
        needs_photon_query=false
        if [[ "${config[alwaysQueryPhoton]}" == "true" ]]; then
            needs_photon_query=true
            log_info "    -> 'Always Query Photon' is enabled. Querying Photon API..."
        elif [[ -z "$country_from_dawarich" || -z "$city_from_dawarich" || -z "$country_code_from_dawarich" ]]; then
             needs_photon_query=true
             log_info "    -> Country, City, or Country Code missing/empty in Dawarich API result. Querying Photon API..."
        fi

        if [[ "$needs_photon_query" == true ]]; then
            location_data_json=$(get_location_from_photon "${config[photonApiUrl]}" "$latitude" "$longitude")
            if [[ -n "$location_data_json" ]]; then
                photon_country=$(echo "$location_data_json" | jq -r '.Country // ""')
                photon_city=$(echo "$location_data_json" | jq -r '.City // ""')
                photon_country_code=$(echo "$location_data_json" | jq -r '.CountryCode // ""')
                log_info "        -> Photon found: Country='$photon_country', City='$photon_city', Code='$photon_country_code'"

                if [[ "${config[alwaysQueryPhoton]}" == "true" ]]; then
                    # Overwrite with Photon data only if Photon provided a non-empty value
                    if [[ -n "$photon_country" ]]; then country_to_write="$photon_country"; fi
                    if [[ -n "$photon_city" ]]; then city_to_write="$photon_city"; fi
                    if [[ -n "$photon_country_code" ]]; then country_code_to_write="$photon_country_code"; fi
                    log_info "        -> Photon results will overwrite Dawarich results where available."
                else
                    # Only fill missing data from Dawarich results
                    if [[ -n "$photon_country" && -z "$country_to_write" ]]; then country_to_write="$photon_country"; fi
                    if [[ -n "$photon_city" && -z "$city_to_write" ]]; then city_to_write="$photon_city"; fi
                    if [[ -n "$photon_country_code" && -z "$country_code_to_write" ]]; then country_code_to_write="$photon_country_code"; fi
                fi
            else
                log_warn "    -> Error during Photon reverse geocoding. Using Dawarich data if available."
            fi
        fi

        # --- Write EXIF/XMP Data ---
        # Check again if lat/lon are valid numbers and not 0,0 before writing
        if [[ "$latitude" =~ ^-?[0-9]+(\.[0-9]+)?$ && "$longitude" =~ ^-?[0-9]+(\.[0-9]+)?$ && ("$latitude" != "0" || "$longitude" != "0") ]]; then
             log_info "    Writing data: Lat=$latitude, Lon=$longitude, Country='$country_to_write', City='$city_to_write', Code='$country_code_to_write'"
             if ! set_exif_data "$exiftool_path_to_use" "$file_path" "$latitude" "$longitude" "$country_to_write" "$city_to_write" "$country_code_to_write"; then
                 file_had_error=true; ((error_count++))
             else
                 ((updated_count++))
             fi
        else
             log_warn "    -> Best match has invalid coordinates (Lat=$latitude, Lon=$longitude). Skipping write operation."
             file_had_error=true; ((error_count++)) # Count as error if we found a match but coords were bad
        fi
    else
        log_info "    -> No suitable GPS data found via Dawarich API for '$filename'."
        # Don't count as error if no API data was found, unless overwrite was true
        if [[ "${config[overwriteExisting]}" == "true" ]]; then
            log_warn "    -> File not updated because no API data found, despite overwrite flag."
            file_had_error=true; ((error_count++))
        fi
    fi

    if [[ "$file_had_error" == false ]]; then
        log_info "---" # Separator
    fi

done # end foreach file

# --- Final Summary ---
echo # Newline
log_info "Processing finished."
log_info " * Files scanned: ${#files_to_process[@]}"
log_info " * Files processed (attempted update): $processed_count"
log_info " * Files updated successfully: $updated_count"
if [[ $error_count -gt 0 ]]; then
    log_warn " * Files with errors or warnings during processing: $error_count"
fi
log_info "Script ended."

exit 0
