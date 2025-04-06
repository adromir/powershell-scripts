# PowerShell EXIF Date Update Script

## Description

This PowerShell script processes image files (JPG, DNG, CR2) within a user-selected folder. It checks if the image files have EXIF DateTimeOriginal data. If this data is missing, it attempts to extract date and time information from the filenames, provided they match the format `IMG_YYYYMMDD_HHMMSS.ext` or `IMG_YYYYMMDD_HHMMSS_TAG.ext` (where `TAG` is a 3-letter identifier). The extracted date and time are then used to update the image file's EXIF DateTimeOriginal and CreateDate tags. Additionally, the file's creation and last write times are modified to reflect this new date and time. The script provides verbose output, displaying the progress and any actions taken during the processing.

## Prerequisites

-   Windows operating system
-   PowerShell
-   ExifTool (must be in your system's PATH)

## How to use

1.  **Save the script:** Save the PowerShell script as a `.ps1` file (e.g., `exif_date_update.ps1`).
2.  **Open PowerShell:** Open a PowerShell window.
3.  **Navigate to the script directory:** Use the `cd` command to navigate to the directory where you saved the script.
4.  **Run the script:** Type `./exif_date_update.ps1` and press Enter.
5.  **Select the folder:** A folder selection dialog will appear. Choose the folder containing the image files you want to process.
6.  **Processing:** The script will process the images, displaying the progress and any actions taken.

## Script Details

-   The script uses a folder selection dialog to allow the user to choose the directory of images to be processed.
-   It searches for files with the extensions `.jpg`, `.dng`, or `.cr2`.
-   If an image file lacks EXIF DateTimeOriginal data, the script attempts to extract date and time information from the filename.
-   Filenames must adhere to the format `IMG_YYYYMMDD_HHMMSS.ext` or `IMG_YYYYMMDD_HHMMSS_TAG.ext`.
-   The script updates the EXIF DateTimeOriginal and CreateDate tags, and modifies the file's creation and last write times.
-   Verbose output is provided, including progress updates and information about processed files.
-   The script also uses the `-if "$IPTCDigest"` and `-IPTCDigest=` parameters for Exiftool.

## Example

```powershell
.\exif_date_update.ps1