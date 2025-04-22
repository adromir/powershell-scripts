# Bash EXIF/XMP Updater Script Geotagging Script with Dawarich and Photon (`geotag_media.sh`)

## Overview

This Bash script automates the process of adding or updating geographical metadata (GPS coordinates, country, city, country code) to image and MP4 files within a specified folder.

It works by:
1.  Reading the creation date from each file's existing EXIF/XMP data.
2.  Querying a primary API (Dawarich, configurable) using the timestamp to find corresponding GPS coordinates.
3.  Optionally querying a secondary reverse geocoding API (Photon, configurable) to find or refine location details (country, city, country code).
4.  Writing the gathered data back to the files using `exiftool`.

The script features a graphical user interface (GUI) built with `zenity` for easy configuration and folder selection.

## Features

* **GUI Configuration:** Uses `zenity` for setting API endpoints, keys, and options.
* **Dependency Check:** Automatically checks for required tools (`exiftool`, `jq`, `zenity`) and attempts installation using the system's package manager (supports `apt`, `yum`, `dnf`, `pacman`, `zypper`).
* **Configuration File:** Loads and saves settings to `~/.config/exif-updater/config.json` for persistence. Handles backward compatibility with older configuration key names.
* **Flexible API Queries:**
    * Queries the primary (Dawarich) API for an exact timestamp match first.
    * If no exact match, queries within a configurable time window around the timestamp.
    * Selects the closest matching data point within the window.
* **Reverse Geocoding:**
    * Optionally queries the secondary (Photon) API if the primary API lacks country/city/code data.
    * Optionally *always* queries the secondary API, allowing its results to override the primary API's location details.
* **Targeted Updates:**
    * Processes only files needing updates (missing required tags) unless the "Overwrite" option is enabled.
* **Smart Metadata Writing (`exiftool`):**
    * **MP4 Files:** Always writes metadata to a separate `.xmp` sidecar file (deleting any pre-existing sidecar first to ensure a clean write). The original MP4 file is *not* modified.
    * **Image Files:**
        * If an `.xmp` sidecar file already exists for the image, it updates the sidecar.
        * If no sidecar exists, it writes the metadata directly into the image file (`-overwrite_original`).
* **Supported File Types:** Searches for common image formats (`.jpg`, `.jpeg`, `.png`, `.tiff`, `.heic`, `.gif`, `.cr2`, `.dng`) and MP4 videos (`.mp4`).
* **Robust Error Handling:** Includes checks for command existence, API errors, file access issues, and invalid data.

## Dependencies

The script requires the following command-line tools to be installed:

1.  **`exiftool`**: The core utility for reading and writing metadata (Package often named `libimage-exiftool-perl` or `perl-image-exiftool`).
2.  **`jq`**: A lightweight command-line JSON processor used for parsing API responses and configuration.
3.  **`zenity`**: Used to display GUI dialogs for configuration and folder selection.

The script will attempt to install these automatically if they are missing and a supported package manager is detected. Manual installation may be required otherwise.

## Installation & Setup

1.  **Save:** Save the script code to a file, e.g., `geotag_media.sh`.
2.  **Make Executable:** Open a terminal and run:
    ```bash
    chmod +x geotag_media.sh
    ```
3.  **Run:** Execute the script from the terminal:
    ```bash
    ./geotag_media.sh
    ```
4.  **First Run & Dependencies:** On the first run (or if dependencies are missing), the script will check for `exiftool`, `jq`, and `zenity`. If missing and a supported package manager is found, it will prompt for `sudo` permission to install them.
5.  **Configuration GUI:** The main configuration window will appear.

## Configuration

Settings are managed via the GUI and optionally saved to `~/.config/exif-updater/config.json`.

* **Dawarich API URL:** The base URL for your primary GPS tracking API endpoint.
* **Dawarich API Key:** Your API key for the primary API.
* **Photon API URL:** The base URL for the Photon reverse geocoding API (defaults to Komoot's public instance).
* **API Time Window (seconds):** The +/- range around the file's timestamp to search in the Dawarich API if an exact match isn't found.
* **Exiftool Path:** The command or full path to the `exiftool` executable. Usually just `exiftool` if it's in your system's PATH.
* **Overwrite existing data?:**
    * `false` (Default): Only process files missing GPS, Country, City, or Country Code.
    * `true`: Process all found files, attempting to update metadata regardless of existing values.
* **Always query Photon API?:**
    * `false` (Default): Only query Photon if Country, City, or Country Code is missing from the Dawarich result.
    * `true`: Always query Photon after getting coordinates from Dawarich. Photon's Country/City/Code results will override Dawarich's if Photon provides them.
* **Save settings?:** Check this (`true`) to save the current configuration to the JSON file for future runs.

## Usage

1.  Run the script: `./geotag_media.sh`
2.  Adjust settings in the configuration GUI and click "OK".
3.  Select the target folder containing your image/video files using the folder selection dialog.
4.  The script will scan the folder, process each file, query APIs, and write metadata as configured. Progress and status messages will be displayed in the terminal.
5.  A final summary shows the number of files scanned, processed, updated, and any errors encountered.

## Important Notes

* **BACKUP YOUR FILES!** While the script aims to be safe (especially with MP4s using sidecars), writing directly to image files carries a risk. Always back up your media library before running bulk metadata operations.
* **API Usage:** Be mindful of the rate limits and terms of service for the Dawarich and Photon APIs you configure. Excessive use could lead to temporary or permanent blocking.
* **XMP Sidecars:** For MP4 files, metadata is *always* written to `.xmp` sidecars. For images, sidecars are used *only if they already exist*. Otherwise, the image file itself is modified.
* **Large Files:** Processing large video files can be slow, primarily due to `exiftool` needing to read parts of the file.
* **Date/Time Accuracy:** The script relies on accurate creation timestamps within the media files (`DateTimeOriginal`, `CreateDate`, etc.). If these are missing or incorrect, the API queries will not yield correct location data.
* **Configuration File Location:** Settings are stored in `$HOME/.config/exif-updater/config.json`.
