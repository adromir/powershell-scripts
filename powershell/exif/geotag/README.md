# PowerShell EXIF Geotagging Script with Dawarich and Photon (`geotag_media.ps1`)

## Purpose

This PowerShell script automates the process of adding or updating location-based metadata (GPS coordinates, and for images: City, Country, Country Code) to image and MP4 video files within a specified folder. It retrieves missing location data by:

1.  Reading the creation date from the file's existing metadata.
2.  Querying the Dawarich API based on the timestamp to find Geolocation for a Media File.
3.  Optionally querying a secondary reverse geocoding API (referred to as "Photon API") if data is missing from the primary API or if configured to always do so (only affects image files).
4.  Writing the retrieved data back to the files using the powerful `exiftool` utility.
5.  Providing a summary at the end, including lists of files that were skipped and why.

## Features

* **GUI Configuration:** Provides a graphical user interface (GUI) on startup to configure API endpoints, API keys, and processing options.
* **Configuration File:** Optionally saves and loads settings to/from a `config.json` file located in the same directory as the script for persistent configuration. Handles backward compatibility with older config file key names.
* **API Integration:**
    * Queries a primary API ("Dawarich") for location data based on timestamps.
    * Queries a secondary reverse geocoding API ("Photon") to find City, Country, and Country Code based on GPS coordinates (used for image files).
* **Flexible Geocoding (for Images):**
    * Option to only query the Photon API if location data is missing from the Dawarich API result.
    * Option to *always* query the Photon API and prioritize its results for City/Country/Country Code for image files.
* **EXIF/XMP Writing:**
    * **Images (JPG, PNG, TIFF, etc.):** Writes GPS, Country, City, and Country Code tags directly into the image file *unless* an `.xmp` sidecar file already exists for that image. If a sidecar exists, it updates the sidecar instead. Uses the `-overwrite_original` flag when writing directly to images.
    * **MP4 Videos:** Writes **only** the GPS coordinate tags (`GPSLatitude`, `GPSLongitude`, `GPSLatitudeRef`, `GPSLongitudeRef`) directly into the MP4 file using `-overwrite_original`. **The original MP4 file is modified.** Country, City, and Country Code are *not* written to MP4 files.
* **Overwrite Option:** Includes an option in the GUI to force the script to process all files and overwrite existing GPS tags (and location tags for images), even if they already contain data.
* **Tag Support:** Writes standard GPS tags (`GPSLatitude`, `GPSLongitude`, `GPSLatitudeRef`, `GPSLongitudeRef`). For images, it also writes `Country`, `City`, and the XMP tag `XMP-iptcCore:CountryCode`.
* **Skipped File Reporting:** Outputs lists at the end detailing which files were skipped because they already had data (and overwrite was off) or because no suitable API data could be found.

## Prerequisites

1.  **PowerShell:** Version 5.1 or higher (Standard on Windows 10/11).
2.  **exiftool:** You *must* download and install `exiftool` by Phil Harvey from the official website: <https://exiftool.org/>
    * Place the `exiftool.exe` executable either:
        * In a directory included in your system's `PATH` environment variable.
        * Or, specify the full path to `exiftool.exe` in the script's configuration GUI or the `config.json` file.

## Configuration

The script uses a GUI for configuration on startup.

1.  **Run the script.** The configuration window will appear.
2.  **Fill in the details:**
    * **Dawarich API URL:** The full URL (including endpoint) for your primary location data API.
    * **Dawarich API Key:** The API key required for the Dawarich API.
    * **Photon API URL:** The base URL for your Photon (Komoot) reverse geocoding instance (e.g., `https://photon.komoot.io`).
    * **API Time Window (seconds):** How many seconds before and after the file's creation time to search in the Dawarich API if an exact timestamp match isn't found.
    * **Exiftool Path:** The path to `exiftool.exe`. Leave as `exiftool.exe` if it's in your system PATH, otherwise provide the full path.
3.  **Select Options:**
    * **Overwrite existing...:** Check this box if you want the script to fetch data and write tags even if the file already has GPS/location information. If unchecked, files with existing data will be skipped. (Applies to GPS for MP4s, all geo tags for images).
    * **Always query Photon API...:** Check this box to force the script to query the Photon API for *every image file* that has GPS coordinates. If checked, the location details (City, Country, Country Code) found by Photon will replace any details returned by the Dawarich API for images. If unchecked, Photon is only queried for images if the Dawarich API result is missing City, Country, or Country Code. (This option does not affect MP4 files).
    * **Save these settings...:** Check this box *before* clicking OK if you want to save the current settings to `config.json` in the script's directory for the next run.
4.  **Click OK** to proceed or **Cancel** to exit.

**`config.json` File:**

* If you check "Save these settings", a file named `config.json` will be created or updated in the same directory as the script.
* On subsequent runs, the script will load settings from this file automatically, pre-populating the GUI.
* **Security Warning:** This file stores your API keys in plain text. Ensure the file and the directory are appropriately secured.

## Usage

1.  Save the script to a file (e.g., `geotag_media.ps1`).
2.  Open a PowerShell terminal.
3.  Navigate to the directory where you saved the script.
4.  Run the script: `.\geotag_media.ps1`
5.  Configure the settings in the GUI that appears and click OK.
6.  Select the target folder containing your media files when prompted by the folder browser dialog.
7.  The script will process the files and output status messages to the console.
8.  At the end, a summary will be displayed, including counts and lists of any skipped files.

## Important Notes

* **BACKUP YOUR FILES!** The script uses `exiftool -overwrite_original` when writing metadata directly into **both MP4 files and image files** (if no sidecar exists for the image). This modifies the original files directly. While generally safe, **it is strongly recommended to back up your media files before running this script.**
* **MP4 Files:** The script *modifies MP4 files directly* to add/update GPS tags. It no longer uses XMP sidecars for MP4s.
* **Large Files:** Processing large files can take time. The script includes a warning for files over 200MB.
* **API Limits:** Be mindful of any rate limits or usage quotas for the APIs you are using. Processing a large number of files may trigger limits.

## Disclaimer
The author is not responsible for any data loss or file corruption that may occur as a result of using this script. **Use at your own risk and always back up important data.**