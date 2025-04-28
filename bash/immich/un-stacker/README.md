# Immich Asset Stacker & Unstacker Scripts

These Bash scripts utilize the Immich API to automatically stack related assets (e.g., JPG + RAW) based on filename patterns or unstack all existing asset stacks.

**Scripts:**

1.  `immich-stacker.sh`: Stacks assets based on user-defined regular expression patterns to identify related files.
2.  `immich-unstacker.sh`: Removes all stacking relationships, separating previously stacked assets.

## Prerequisites

Before using these scripts, ensure you have the following installed on your system:

* **`curl`**: A command-line tool for transferring data with URLs. (Usually pre-installed on Linux/macOS).
* **`jq`**: A lightweight and flexible command-line JSON processor.
    * Install on Debian/Ubuntu: `sudo apt update && sudo apt install jq`
    * Install on Fedora: `sudo dnf install jq`
    * Install on macOS (using Homebrew): `brew install jq`

## Configuration

Both scripts require configuration before the first run. Edit the script files directly:

1.  **`IMMICH_URL`**: Set this variable to the full base URL of your Immich instance (e.g., `http://192.168.1.100:2283` or `https://immich.yourdomain.com`). **Do not include a trailing slash (`/`)**.
2.  **`API_KEY`**: Set this variable to a valid API Key generated within your Immich user settings. This key needs permission to read assets and modify stacks.
3.  **`DRY_RUN`** (Optional, Recommended for first runs):
    * Set to `true` to simulate the script's actions without making any actual changes via the API. It will print what it *would* do.
    * Set to `false` to perform the actual stacking or unstacking operations. **Default is `false`**.
4.  **`VERBOSE`** (Optional):
    * Set to `true` to enable detailed debug messages during script execution. Useful for troubleshooting.
    * Set to `false` for standard output. **Default is `false`**.

### Stacker (`immich-stacker.sh`) Specific Configuration

* **`PRIMARY_EXTENSIONS`**: An array of lowercase file extensions (without the dot) that should be considered the "primary" file in a stack (often the cover image, like JPGs or HEICs). Example: `("jpg" "jpeg" "heic")`
* **`RAW_EXTENSIONS`**: An array of lowercase file extensions (without the dot) that represent the secondary or RAW files to be stacked *with* a primary file. Example: `("dng" "cr2" "nef")`
* **`FILENAME_REGEX_PATTERNS`**: **This is crucial.** An array of POSIX Extended Regular Expressions (ERE).
    * Each pattern is tried against the `originalFileName` of an asset.
    * **Each pattern MUST contain exactly ONE capturing group `(...)`**. This group must capture the common base identifier shared between related files (e.g., `IMG_1234` from `IMG_1234.JPG` and `IMG_1234.DNG`).
    * The script uses the *first* pattern that matches. Order can matter if filenames could match multiple patterns.
    * Add or modify patterns to match the naming schemes used by your cameras or devices. Test your regex patterns independently first!

### Unstacker (`immich-unstacker.sh`) Specific Configuration

* This script primarily uses `IMMICH_URL`, `API_KEY`, `DRY_RUN`, and `VERBOSE`. No extension or pattern configuration is needed.
* **API Endpoint Verification**: The script uses `PUT /api/assets/{parentId}/stack/remove` by default. While this is a common pattern, **verify this endpoint** in the API documentation (`<IMMICH_URL>/api`) for your specific Immich version. If it differs, update the `unstack_endpoint` variable within the script's main logic section.

## Usage

1.  **Save the Scripts:** Save the code for the stacker and unstacker into separate files (e.g., `immich_stacker.sh` and `immich_unstacker.sh`).
2.  **Make Executable:** Open your terminal and grant execute permissions to the scripts:
    ```bash
    chmod +x immich-stacker.sh
    chmod +x immich_unstacker.sh
    ```
3.  **Configure:** Edit the scripts as described in the "Configuration" section above.
4.  **Run (Dry Run First!):** It is **highly recommended** to run the scripts with `DRY_RUN=true` first to ensure they identify the correct assets and actions.
    ```bash
    # Example Dry Run for Stacker
    ./immich_stacker.sh

    # Example Dry Run for Unstacker
    ./immich_unstacker_en.sh
    ```
    Review the output carefully. If you want more detail, set `VERBOSE=true` as well.
5.  **Run (Live):** Once you are confident with the dry run output, edit the desired script, set `DRY_RUN=false`, and run it again to apply the changes to your Immich library.
    ```bash
    # Example Live Run for Stacker
    ./immich_stacker.sh

    # Example Live Run for Unstacker
    ./immich_unstacker.sh
    ```

## Important Notes

* **BACKUP YOUR IMMICH DATA:** Before running these scripts in live mode (`DRY_RUN=false`), ensure you have a reliable backup of your Immich database and library. Mistakes in configuration or unexpected API behavior could lead to unwanted changes.
* **API Rate Limiting:** The scripts include a small `sleep 0.5` delay between API calls to avoid overwhelming the Immich server. If you encounter rate-limiting issues (e.g., HTTP 429 errors), you might need to increase this delay.
* **Large Libraries:** For very large libraries (tens or hundreds of thousands of assets), the initial step of fetching all assets might be slow or memory-intensive. Future script versions might need pagination if this becomes an issue.
* **Error Handling:** The scripts perform basic checks for API call success (HTTP status codes 200/201 for stacking, 200 for unstacking). Review the output for any reported errors. Verbose mode can help diagnose issues.
* **Idempotency:**
    * The **stacker** script attempts to be idempotent – running it multiple times should ideally not create duplicate stacks or cause errors if assets are already stacked correctly. It checks `stackParentId` and potentially stack children before attempting to stack.
    * The **unstacker** script is generally idempotent – running it again after everything is unstacked will simply find no stacks to process.

## Disclaimer
The author is not responsible for any data loss or file corruption that may occur as a result of using this script. **Use at your own risk and always back up important data.**
